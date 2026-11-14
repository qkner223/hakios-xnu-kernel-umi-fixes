/*
 * 20F66 InstalledContentLibrary calls libmis through a direct branch island,
 * bypassing dyld interposition. MISValidateSignatureAndCopyInfo is only an
 * eight-byte tail wrapper; hook its WithProgress implementation instead.
 * Keep the real validator for Apple signatures, and supply installation
 * metadata for ad-hoc code without requiring a provisioning profile. Unsigned
 * code, and code whose signature libmis refused, must first acquire a real
 * on-disk ad-hoc signature for FrontBoard's validator.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/param.h>
#include <sys/stat.h>
#include <unistd.h>

/* Exported by iOS Security, but omitted from the iOS SDK's public headers. */
typedef const struct __SecCode *SecStaticCodeRef;
typedef struct __SecCodeSigner *SecCodeSignerRef;
extern int32_t SecStaticCodeCreateWithPath(CFURLRef, uint32_t, SecStaticCodeRef *);
extern int32_t SecCodeCopySigningInformation(SecStaticCodeRef, uint32_t, CFDictionaryRef *);
extern int32_t SecStaticCodeCheckValidity(SecStaticCodeRef, uint32_t, const void *);
extern int32_t SecCodeSignerCreate(CFDictionaryRef, uint32_t, SecCodeSignerRef *);
extern int32_t SecCodeSignerAddSignatureWithErrors(SecCodeSignerRef, SecStaticCodeRef, uint32_t, CFErrorRef *);
extern const CFStringRef kSecCodeSignerIdentity, kSecCodeSignerIdentifier, kSecCodeSignerEntitlements;
extern const CFStringRef kSecCodeInfoFlags, kSecCodeInfoCMS, kSecCodeInfoUnique;
extern const CFStringRef kSecCodeInfoEntitlementsDict, kSecCodeInfoIdentifier;
extern const CFStringRef kSecCodeInfoTeamIdentifier, kSecCodeInfoMainExecutable;
extern const CFStringRef kSecCodeInfoSignatureVersion;

/* Fourth argument is libmis's optional progress block; forward it unchanged. */
typedef int (*mis_fn)(CFStringRef, CFDictionaryRef, CFDictionaryRef *, const void *);
static mis_fn original_mis;
static CFStringRef signer_key, cdhash_key, entitlements_key, identifier_key, team_key;
static CFStringRef version_key, profile_key, local_profile_key, universal_profile_key;

static void
say(const char *format, ...)
{
	char line[2048];
	va_list ap;
	va_start(ap, format);
	int n = vsnprintf(line, sizeof(line), format, ap);
	va_end(ap);
	if (n > 0) {
		write(2, line, (size_t)n < sizeof(line) ? (size_t)n : sizeof(line) - 1);
	}
}

/* The highest LC_ENCRYPTION_INFO(_64) cryptid of any slice. Nonzero is
 * FairPlay-encrypted App Store text, which can never be decrypted here. */
static uint32_t
fairplay_cryptid(const char *path)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0) return 0;
	uint32_t head[2] = {0}, cryptid = 0, slices = 1;
	bool fat = pread(fd, head, sizeof(head), 0) == sizeof(head) &&
	    (head[0] == FAT_CIGAM || head[0] == FAT_CIGAM_64);
	if (fat) slices = OSSwapBigToHostInt32(head[1]);
	for (uint32_t i = 0; i < slices; i++) {
		uint64_t offset = 0;
		if (fat && head[0] == FAT_CIGAM_64) {
			struct fat_arch_64 arch;
			if (pread(fd, &arch, sizeof(arch), sizeof(struct fat_header) + i * sizeof(arch)) != sizeof(arch)) break;
			offset = OSSwapBigToHostInt64(arch.offset);
		} else if (fat) {
			struct fat_arch arch;
			if (pread(fd, &arch, sizeof(arch), sizeof(struct fat_header) + i * sizeof(arch)) != sizeof(arch)) break;
			offset = OSSwapBigToHostInt32(arch.offset);
		}
		struct mach_header_64 header;
		if (pread(fd, &header, sizeof(header), (off_t)offset) != sizeof(header) ||
		    (header.magic != MH_MAGIC && header.magic != MH_MAGIC_64)) continue;
		off_t start = (off_t)offset + (header.magic == MH_MAGIC_64 ? sizeof(header) : sizeof(struct mach_header));
		uint8_t *commands = malloc(header.sizeofcmds);
		if (commands && pread(fd, commands, header.sizeofcmds, start) == (ssize_t)header.sizeofcmds) {
			for (uint32_t at = 0, n = 0; n < header.ncmds &&
			    at + sizeof(struct encryption_info_command) <= header.sizeofcmds; n++) {
				const struct encryption_info_command *command = (const void *)(commands + at);
				if ((command->cmd == LC_ENCRYPTION_INFO || command->cmd == LC_ENCRYPTION_INFO_64) &&
				    command->cryptid > cryptid) cryptid = command->cryptid;
				if (command->cmdsize < 8) break;
				at += command->cmdsize;
			}
		}
		free(commands);
	}
	close(fd);
	return cryptid;
}

/* An ad-hoc CodeDirectory: kSecCodeSignatureAdhoc and no CMS blob. */
static bool
adhoc_signature(CFDictionaryRef signing)
{
	int flags = 0;
	CFNumberRef number = CFDictionaryGetValue(signing, kSecCodeInfoFlags);
	CFDataRef cms = CFDictionaryGetValue(signing, kSecCodeInfoCMS);
	return number != NULL && CFGetTypeID(number) == CFNumberGetTypeID() &&
	    CFNumberGetValue(number, kCFNumberIntType, &flags) && (flags & 2) &&
	    (cms == NULL || (CFGetTypeID(cms) == CFDataGetTypeID() && !CFDataGetLength(cms)));
}

/* Sign inside-out so a bundle's resource seal sees the final nested binaries.
 * Unless resign is set, existing signatures (including ad-hoc frameworks) are
 * left intact; with it, every code signature is replaced, keeping its
 * entitlements. Security owns Mach-O/load-command allocation, fat slices,
 * hashing and XML/DER encoding. These signer APIs are implemented and exported
 * by 20F66 Security, not stubs. *count is the number of Mach-Os signed. */
static bool
sign_path(const char *path, const char *outer_executable, bool resign, unsigned *count)
{
	struct stat st;
	if (lstat(path, &st) != 0) {
		say("hakios-installd: signing stat failed: %s errno=%d\n", path, errno);
		return false;
	}
	bool directory = S_ISDIR(st.st_mode);
	if (!directory) {
		if (!S_ISREG(st.st_mode) || (outer_executable && !strcmp(path, outer_executable))) return true;
		int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
		if (fd < 0) return false;
		struct mach_header header = {0};
		ssize_t n = pread(fd, &header, sizeof(header), 0);
		close(fd);
		if (n < 0) return false;
		uint32_t magic = header.magic;
		if (n < (ssize_t)sizeof(magic) || (magic != MH_MAGIC && magic != MH_MAGIC_64 &&
		    magic != MH_CIGAM && magic != MH_CIGAM_64 && magic != FAT_MAGIC &&
		    magic != FAT_CIGAM && magic != FAT_MAGIC_64 && magic != FAT_CIGAM_64)) return true;
		if (n != sizeof(header)) return false;
		if (magic == MH_MAGIC || magic == MH_MAGIC_64 || magic == MH_CIGAM || magic == MH_CIGAM_64) {
			uint32_t type = (magic == MH_CIGAM || magic == MH_CIGAM_64) ?
			    CFSwapInt32(header.filetype) : header.filetype;
			if (type != MH_EXECUTE && type != MH_DYLIB && type != MH_BUNDLE) return true;
		}
	}
	CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), directory);
	CFDictionaryRef bundle = directory ? CFBundleCopyInfoDictionaryForURL(url) : NULL;
	bool is_code = !directory || (bundle && CFDictionaryContainsKey(bundle, CFSTR("CFBundleExecutable")));
	SecStaticCodeRef code = NULL;
	CFDictionaryRef signing = NULL;
	char executable[MAXPATHLEN] = "";
	bool ok = false;
	int32_t status = 0;
	if (is_code) {
		status = SecStaticCodeCreateWithPath(url, 0, &code);
		if (status != 0) goto out;
		status = SecCodeCopySigningInformation(code, 0x23, &signing);
		if (status != 0) goto out;
		if (!resign && CFDictionaryContainsKey(signing, kSecCodeInfoIdentifier)) {
			ok = true;
			goto out;
		}
		CFURLRef main = CFDictionaryGetValue(signing, kSecCodeInfoMainExecutable);
		if (!main || !CFURLGetFileSystemRepresentation(main, true, (UInt8 *)executable, sizeof(executable))) goto out;
		/* Checked before any nested code is touched: signing cannot make it run. */
		uint32_t cryptid = fairplay_cryptid(executable);
		if (cryptid != 0) {
			say("hakios-installd: %s %s is FairPlay-encrypted (cryptid=%u); a decrypted IPA is needed\n",
			    path, outer_executable ? "executable" : "main executable", cryptid);
			goto out;
		}
	}
	if (directory) {
		DIR *dir = opendir(path);
		if (!dir) goto out;
		struct dirent *entry;
		ok = true;
		for (;;) {
			errno = 0;
			entry = readdir(dir);
			if (!entry) { if (errno) ok = false; break; }
			if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
			char child[MAXPATHLEN];
			if (snprintf(child, sizeof(child), "%s/%s", path, entry->d_name) >= (int)sizeof(child) ||
			    !sign_path(child, is_code ? executable : outer_executable, resign, count)) {
				ok = false;
				break;
			}
		}
		closedir(dir);
		if (!ok || !is_code) goto out;
	}
	CFStringRef identifier = bundle ? CFDictionaryGetValue(bundle, kCFBundleIdentifierKey) : NULL;
	CFStringRef filename = !directory ? CFURLCopyLastPathComponent(url) : NULL;
	if (!identifier) identifier = filename;
	ok = false;
	if (identifier && CFGetTypeID(identifier) == CFStringGetTypeID() && CFStringGetLength(identifier)) {
		/* A replaced signature keeps its entitlements; application-identifier
		 * is added only when absent, as sideload_info does for the record. */
		CFDictionaryRef old = CFDictionaryGetValue(signing, kSecCodeInfoEntitlementsDict);
		CFMutableDictionaryRef entitlements = old != NULL && CFGetTypeID(old) == CFDictionaryGetTypeID() ?
		    CFDictionaryCreateMutableCopy(NULL, 0, old) : CFDictionaryCreateMutable(NULL, 0,
		    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
		if (!CFDictionaryContainsKey(entitlements, CFSTR("application-identifier")))
			CFDictionarySetValue(entitlements, CFSTR("application-identifier"), identifier);
		CFDataRef xml = CFPropertyListCreateData(NULL, entitlements, kCFPropertyListXMLFormat_v1_0, 0, NULL);
		/* kSecCodeSignerEntitlements takes an EntitlementsBlob, including its
		 * big-endian magic/length header, rather than a bare XML plist. */
		uint32_t header[] = { CFSwapInt32HostToBig(0xfade7171),
		    CFSwapInt32HostToBig((uint32_t)CFDataGetLength(xml) + 8) };
		CFMutableDataRef blob = CFDataCreateMutable(NULL, 0);
		CFDataAppendBytes(blob, (const UInt8 *)header, sizeof(header));
		CFDataAppendBytes(blob, CFDataGetBytePtr(xml), CFDataGetLength(xml));
		const void *keys[] = { kSecCodeSignerIdentity, kSecCodeSignerIdentifier, kSecCodeSignerEntitlements };
		const void *values[] = { kCFNull, identifier, blob };
		CFDictionaryRef parameters = CFDictionaryCreate(NULL, keys, values, 3,
		    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
		SecCodeSignerRef signer = NULL;
		CFErrorRef error = NULL;
		status = SecCodeSignerCreate(parameters, 0, &signer);
		if (status == 0) status = SecCodeSignerAddSignatureWithErrors(signer, code, 0, &error);
		ok = status == 0;
		if (error) CFRelease(error);
		if (signer) CFRelease(signer);
		CFRelease(parameters);
		CFRelease(blob);
		CFRelease(xml);
		CFRelease(entitlements);
		if (ok) {
			(*count)++;
			say("hakios-installd: ad-hoc signed %s\n", path);
		}
	}
	if (filename) CFRelease(filename);
out:
	if (!ok) say("hakios-installd: ad-hoc signing failed: %s status=%d\n", path, status);
	if (signing) CFRelease(signing);
	if (code) CFRelease(code);
	if (bundle) CFRelease(bundle);
	CFRelease(url);
	return ok;
}

static CFDictionaryRef
sideload_info(CFStringRef path, const char **origin, CFDictionaryRef validated_info)
{
	CFURLRef url = CFURLCreateWithFileSystemPath(NULL, path, kCFURLPOSIXPathStyle, false);
	SecStaticCodeRef code = NULL;
	CFDictionaryRef signing = NULL;
	CFMutableDictionaryRef result = NULL;
	CFDataRef hash = NULL;
	CFMutableDictionaryRef entitlements = NULL;
	CFNumberRef version = NULL;
	int32_t status = SecStaticCodeCreateWithPath(url, 0, &code);
	if (status != 0) {
		CFRelease(url);
		return NULL;
	}
	/* Same flags as libmis at 0x1d11fb9a4: Internal | Signing | SkipResourceDirectory.
	 * Includes the CodeDirectory version and XML/DER entitlements without a
	 * trust/profile or resource-seal validation. */
	status = SecCodeCopySigningInformation(code, 0x23, &signing);
	if (status != 0) {
		CFRelease(code);
		CFRelease(url);
		return NULL;
	}
	bool is_unsigned = !CFDictionaryContainsKey(signing, kSecCodeInfoIdentifier);
	/* After a libmis refusal only an intact ad-hoc signature is kept. Any other
	 * (certificate, Info.plist or resource seal modified, revoked, untrusted)
	 * is replaced ad-hoc, the same way unsigned code is signed. */
	int32_t validity = is_unsigned || validated_info != NULL ? 0 : SecStaticCodeCheckValidity(code, 0, NULL);
	bool resign = !is_unsigned && validated_info == NULL && (validity != 0 || !adhoc_signature(signing));
	CFRelease(code);
	*origin = is_unsigned ? "unsigned -> ad-hoc" : resign ? "re-signed -> ad-hoc" : "ad-hoc";
	if (is_unsigned || resign) {
		char name[MAXPATHLEN];
		unsigned count = 0;
		if (!CFURLGetFileSystemRepresentation(url, true, (UInt8 *)name, sizeof(name)) ||
		    !sign_path(name, NULL, resign, &count)) goto out;
		if (resign) {
			say("hakios-installd: re-signed ad-hoc (was: %s signature, status=%d) %u Mach-Os: %s\n",
			    adhoc_signature(signing) ? "ad-hoc" : "certificate", validity, count, name);
		}
		/* Discard Security's cached unsigned view. Only the new on-disk
		 * CodeDirectory may supply the hash, version and entitlements to MI/LS.
		 * FBS _validateApp: (20F66 0x19b90fd00) independently calls libmis;
		 * an executable digest in the installation record cannot satisfy it. */
		CFRelease(signing);
		signing = NULL;
		status = SecStaticCodeCreateWithPath(url, 0, &code);
		if (status != 0) goto out;
		status = SecCodeCopySigningInformation(code, 0x23, &signing);
		CFRelease(code);
		if (status != 0) goto out;
		validated_info = NULL;
	}
	CFStringRef identifier = CFDictionaryGetValue(signing, kSecCodeInfoIdentifier);
	{
		if (!adhoc_signature(signing)) {
			goto out; /* A certificate signature stays with the real validator. */
		}
		hash = CFDictionaryGetValue(signing, kSecCodeInfoUnique);
		if (hash != NULL) {
			CFRetain(hash);
		}
		version = CFDictionaryGetValue(signing, kSecCodeInfoSignatureVersion);
		if (version != NULL) {
			CFRetain(version);
		}
	}
	/* 0x1b1196558 reads SigningID as NSString; 0x1b11838d0 then compares it
	 * with CFBundleIdentifier. Preserve the real signing ID for signed code. */
	if (identifier == NULL || CFGetTypeID(identifier) != CFStringGetTypeID() ||
	    CFStringGetLength(identifier) == 0 || version == NULL || CFGetTypeID(version) != CFNumberGetTypeID()) {
		goto out;
	}
	if (hash == NULL || CFGetTypeID(hash) != CFDataGetTypeID() || CFDataGetLength(hash) != 20) {
		goto out;
	}
	CFDictionaryRef existing = validated_info != NULL ?
	    CFDictionaryGetValue(validated_info, entitlements_key) : NULL;
	if (existing == NULL) existing = CFDictionaryGetValue(signing, kSecCodeInfoEntitlementsDict);
	if (existing != NULL) {
		if (CFGetTypeID(existing) != CFDictionaryGetTypeID()) {
			goto out;
		}
		entitlements = CFDictionaryCreateMutableCopy(NULL, 0, existing);
	} else {
		entitlements = CFDictionaryCreateMutable(NULL, 0,
		    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	}
	/* 20F66 installd's _validateApplicationIdentifierForNewBundleSigningInfo:
	 * at 0x100033ba0 uses 0x10003bf24: an NSString lookup, with no team-prefix
	 * requirement. Use the signing ID (CFBundleIdentifier for unsigned code)
	 * when absent; never replace an existing entitlement, including its prefix.
	 * MIKeychainAccessGroupTracker at 0x1b116dd84 includes this ID itself, so
	 * keychain-access-groups is optional (and prohibited for App Clips at
	 * 0x100034f78). Team/get-task-allow are not required by this install path.
	 * These are installation records only, not executable/kernel entitlements. */
	if (!CFDictionaryContainsKey(entitlements, CFSTR("application-identifier"))) {
		CFDictionarySetValue(entitlements, CFSTR("application-identifier"), identifier);
		char name[MAXPATHLEN] = "?", app_id[512] = "?";
		CFStringGetCString(path, name, sizeof(name), kCFStringEncodingUTF8);
		CFStringGetCString(identifier, app_id, sizeof(app_id), kCFStringEncodingUTF8);
		say("hakios-installd: %s entitlements: added application-identifier=%s\n", name, app_id);
	}
	if (validated_info != NULL) {
		/* Successful ad-hoc validation still needs the missing identifier.
		 * Preserve all of libmis's other result fields and entitlement values. */
		result = CFDictionaryCreateMutableCopy(NULL, 0, validated_info);
		CFDictionarySetValue(result, entitlements_key, entitlements);
		goto out;
	}
	result = CFDictionaryCreateMutable(NULL, 0,
	    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	/* 20F66 MICodeSigningVerifier accepts 2 without a profile. 5 is explicitly
	 * rejected by its signer-type switch at 0x1b1195f1c. Use a CFNumber, not a string. */
	int signer = 2;
	CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &signer);
	CFDictionarySetValue(result, signer_key, number);
	CFRelease(number);
	CFDictionarySetValue(result, cdhash_key, hash);
	CFDictionarySetValue(result, entitlements_key, entitlements);
	CFDictionarySetValue(result, identifier_key, identifier);
	CFDictionarySetValue(result, version_key, version);
	/* _getMICodeSignerTypeFromMISInfoDict: reads these three booleans at
	 * 0x1b1195dfc..0x1b1195f10. False means no provisioning profile (type 1).
	 * No isAdHoc info key is read. A missing SignerCertificate is allowed when
	 * allowAdhocSigning is true (0x1b1196900), as in this install path; TeamID
	 * is optional (0x1b1196914..0x1b1196c5c). Do not invent either identity. */
	CFDictionarySetValue(result, profile_key, kCFBooleanFalse);
	CFDictionarySetValue(result, local_profile_key, kCFBooleanFalse);
	CFDictionarySetValue(result, universal_profile_key, kCFBooleanFalse);
	CFStringRef team = CFDictionaryGetValue(signing, kSecCodeInfoTeamIdentifier);
	if (team != NULL) {
		CFDictionarySetValue(result, team_key, team);
	}
out:
	if (version != NULL) CFRelease(version);
	if (entitlements != NULL) CFRelease(entitlements);
	if (hash != NULL) CFRelease(hash);
	if (signing != NULL) CFRelease(signing);
	CFRelease(url);
	return result;
}

static int
hakios_mis(CFStringRef path, CFDictionaryRef options, CFDictionaryRef *info, const void *progress)
{
	char name[MAXPATHLEN] = "?";
	CFDictionaryRef original_info = NULL;
	int rc = original_mis(path, options, &original_info, progress);
	if (path != NULL) {
		CFStringGetCString(path, name, sizeof(name), kCFStringEncodingUTF8);
	}
	if (rc == 0) {
		CFDictionaryRef entitlements = original_info != NULL ?
		    CFDictionaryGetValue(original_info, entitlements_key) : NULL;
		if (path != NULL && original_info != NULL && (entitlements == NULL ||
		    (CFGetTypeID(entitlements) == CFDictionaryGetTypeID() &&
		    !CFDictionaryContainsKey(entitlements, CFSTR("application-identifier"))))) {
			const char *origin = NULL;
			/* sideload_info checks CodeDirectory flags and CMS before editing;
			 * a successful Apple/certificate signature is returned unchanged. */
			CFDictionaryRef supplemented = sideload_info(path, &origin, original_info);
			if (supplemented != NULL) {
				CFRelease(original_info);
				original_info = supplemented;
			}
		}
		if (info != NULL) *info = original_info;
		else if (original_info != NULL) CFRelease(original_info);
		say("hakios-installd: %s valid (libmis)\n", name);
		return 0;
	}
	if (original_info != NULL) CFRelease(original_info);
	if (info != NULL) *info = NULL;
	const char *origin = NULL;
	CFDictionaryRef accepted = path != NULL ? sideload_info(path, &origin, NULL) : NULL;
	if (accepted == NULL) {
		say("hakios-installd: %s refused (libmis rc=%d; no ad-hoc/unsigned metadata)\n", name, rc);
		return rc;
	}
	char identifier[512] = "?";
	int version = 0;
	CFStringGetCString(CFDictionaryGetValue(accepted, identifier_key), identifier, sizeof(identifier),
	    kCFStringEncodingUTF8);
	CFNumberGetValue(CFDictionaryGetValue(accepted, version_key), kCFNumberIntType, &version);
	char cdhash[41];
	const UInt8 *bytes = CFDataGetBytePtr(CFDictionaryGetValue(accepted, cdhash_key));
	for (unsigned i = 0; i < 20; i++) snprintf(cdhash + i * 2, 3, "%02x", bytes[i]);
	say("hakios-installd: %s accepted (%s, rc was %d) signerType=2 cdhash=%s entitlements=%ld "
	    "SigningID=%s SignatureVersion=0x%x profile=no team=%s\n",
	    name, origin, rc, cdhash,
	    (long)CFDictionaryGetCount(CFDictionaryGetValue(accepted, entitlements_key)), identifier, version,
	    CFDictionaryContainsKey(accepted, team_key) ? "present" : "absent");
	if (info != NULL) *info = accepted;
	else CFRelease(accepted);
	return 0;
}

/* ldr x16, .+8; br x16; .quad target. x16 is the ABI's branch scratch
 * register. These are raw arm64 addresses, not arm64e signed function pointers. */
static void
absolute_branch(void *where, const void *target)
{
	const uint32_t instructions[] = { 0x58000050, 0xd61f0200 };
	memcpy(where, instructions, sizeof(instructions));
	memcpy((char *)where + 8, &target, sizeof(target));
}

static CFStringRef
mis_key(void *libmis, const char *symbol)
{
	const CFStringRef *key = dlsym(libmis, symbol);
	return key != NULL ? *key : NULL;
}

#ifndef HAKIOS_INSTALLD_HOST_TEST
__attribute__((constructor))
#endif
static void
hakios_installd_loaded(void)
{
	say("hakios-installd: loaded\n");
	const struct mach_header *process = _dyld_get_image_header(0);
	/* This payload/cache is iPhone10,3 20F66 arm64, as is Snapdragon 865.
	 * An arm64e/PAC build needs its own authenticated prologue relocation. */
	if (process->cputype != CPU_TYPE_ARM64 ||
	    (process->cpusubtype & ~CPU_SUBTYPE_MASK) != CPU_SUBTYPE_ARM64_ALL) {
		say("hakios-installd: hook refused: unsupported CPU subtype (arm64e/PAC)\n");
		return;
	}
	void *libmis = dlopen("/usr/lib/libmis.dylib", RTLD_NOW | RTLD_LOCAL);
	void *entry = libmis != NULL ? dlsym(libmis, "MISValidateSignatureAndCopyInfoWithProgress") : NULL;
	/* Exactly the first four 20F66 instructions: sub sp; stp; stp; stp.
	 * None is PC-relative or signs LR. Never blindly copy a different prologue. */
	const uint32_t prologue[] = { 0xd105c3ff, 0xa9116ffc, 0xa91267fa, 0xa9135ff8 };
	if (entry == NULL || memcmp(entry, prologue, sizeof(prologue)) != 0) {
		say("hakios-installd: hook refused: libmis is not the expected 20F66 arm64 entry\n");
		return;
	}
	signer_key = mis_key(libmis, "kMISValidationInfoSignerType");
	cdhash_key = mis_key(libmis, "kMISValidationInfoCdHash");
	entitlements_key = mis_key(libmis, "kMISValidationInfoEntitlements");
	identifier_key = mis_key(libmis, "kMISValidationInfoSigningID");
	team_key = mis_key(libmis, "kMISValidationInfoTeamID");
	version_key = mis_key(libmis, "kMISValidationInfoCDVersion");
	profile_key = mis_key(libmis, "kMISValidationInfoValidatedByProfile");
	local_profile_key = mis_key(libmis, "kMISValidationInfoValidatedByLocalProfile");
	universal_profile_key = mis_key(libmis, "kMISValidationInfoValidatedByUniversalProfile");
	if (!signer_key || !cdhash_key || !entitlements_key || !identifier_key || !team_key ||
	    !version_key || !profile_key || !local_profile_key || !universal_profile_key) {
		say("hakios-installd: hook refused: missing libmis info keys\n");
		return;
	}
	vm_address_t trampoline = 0;
	kern_return_t kr = vm_allocate(mach_task_self(), &trampoline, vm_page_size, VM_FLAGS_ANYWHERE);
	if (kr != KERN_SUCCESS) {
		say("hakios-installd: trampoline allocate failed: %d\n", kr);
		return;
	}
	memcpy((void *)trampoline, prologue, sizeof(prologue));
	absolute_branch((void *)(trampoline + sizeof(prologue)), (char *)entry + sizeof(prologue));
	kr = vm_protect(mach_task_self(), trampoline, vm_page_size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
	if (kr != KERN_SUCCESS) goto fail;
	sys_icache_invalidate((void *)trampoline, 32);
	vm_address_t page = (vm_address_t)entry & ~((vm_address_t)vm_page_size - 1);
	vm_size_t size = (((vm_address_t)entry + sizeof(prologue) - page + vm_page_size - 1) /
	    vm_page_size) * vm_page_size;
	/* vm_map_protect(VM_PROT_COPY) remaps the cache text copy-on-write, so
	 * other processes and the on-disk cache keep the original instructions.
	 * No W+X mapping: write privately, restore RX, then invalidate I-cache. */
	kr = vm_protect(mach_task_self(), page, size, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
	if (kr != KERN_SUCCESS) goto fail;
	original_mis = (mis_fn)trampoline;
	absolute_branch(entry, (const void *)hakios_mis);
	kr = vm_protect(mach_task_self(), page, size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
	if (kr != KERN_SUCCESS) {
		/* Do not let dyld enter a partially installed/non-executable hook. */
		say("hakios-installd: hook RX restore failed: %d\n", kr);
		_exit(1);
	}
	sys_icache_invalidate(entry, sizeof(prologue));
	say("hakios-installd: MISValidate hooked at %p (WithProgress, arm64, trampoline=%p)\n",
	    entry, (void *)trampoline);
	return;
fail:
	say("hakios-installd: hook vm_protect failed: %d\n", kr);
	vm_deallocate(mach_task_self(), trampoline, vm_page_size);
}
