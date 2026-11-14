/*
 * A function's specialization values, and the exact path for CoreAnimation pipelines the pipeline library does not
 * have. Shared by the plug-in (HakiosMetalCA.m) and the host regression (hakios-metal/tests/ca_exact.mm), which runs
 * this very code against the real Metal API.
 *
 * iOS 16.5's CoreAnimation specialises its OWN library's functions (QuartzCore.framework/default.metallib of the same
 * image, 141 functions) with NAMED constants: -[MTLFunctionConstantValues setConstantValue:type:withName:] with the
 * fc_* names in QuartzCore's string table. Metal keeps a named value only when the function declares a constant of
 * that name. The earlier ca-share library put pipelinelib variants in place of the four uber shaders: those are
 * already specialised and declare no constants (functionConstantsDictionary: 0 entries on the phone), so every value
 * CoreAnimation passed was dropped and "missing named constant fc_vertex_layout" followed. With the original library
 * fixed_frag_lph_cph declares all 58 constants CoreAnimation sets, fixed_vert_lph_spc its 4, and the exact program is
 * simply the function's own AIR with the values Metal recorded -- the same specialisation Apple's compiler makes.
 * The dedicated functions (downsample_4_frag, narrow_blur_*, home_affordance_base, attachment_clear, ...) declare no
 * constants and are compiled as they are.
 */

/* The values a pipeline's function was specialised with (-[MTLLibrary newFunctionWithName:constantValues:error:]), as
 * hakios-metal's compiler takes them: each constant the function declares (functionConstantsDictionary: name to
 * MTLFunctionConstant, its index and type) with the value -[_MTLFunctionInternal baseFunctionConstantValues] holds
 * for it (-constantValueWithFunctionConstant:, a pointer to the value's bytes, or NULL when none was given). The bytes
 * go into the 64-bit word as they lie, which is the component-at-i-times-width packing the C interface asks for; a
 * constant the function declares and nobody set is left out, which tells the front end it is not defined. *COUNT
 * the number written, at most MAX. Read off this Metal's own classes by selector (Metal.framework's class dump):
 * nothing of their layout is assumed. */
static unsigned
hm_data_type_bytes(MTLDataType t)
{
	switch (t) {
	case MTLDataTypeBool: case MTLDataTypeChar: case MTLDataTypeUChar: return 1;
	case MTLDataTypeBool2: case MTLDataTypeChar2: case MTLDataTypeUChar2: case MTLDataTypeShort: case MTLDataTypeUShort: case MTLDataTypeHalf: return 2;
	case MTLDataTypeBool3: case MTLDataTypeChar3: case MTLDataTypeUChar3: return 3;
	case MTLDataTypeBool4: case MTLDataTypeChar4: case MTLDataTypeUChar4: case MTLDataTypeShort2: case MTLDataTypeUShort2: case MTLDataTypeHalf2:
	case MTLDataTypeInt: case MTLDataTypeUInt: case MTLDataTypeFloat: return 4;
	case MTLDataTypeShort3: case MTLDataTypeUShort3: case MTLDataTypeHalf3: return 6;
	case MTLDataTypeShort4: case MTLDataTypeUShort4: case MTLDataTypeHalf4: case MTLDataTypeInt2: case MTLDataTypeUInt2: case MTLDataTypeFloat2:
	case MTLDataTypeLong: case MTLDataTypeULong: return 8;
	default: return 0;   /* wider than the word the front end takes: left out, and the module refuses what it cannot fold */
	}
}

/* A specialised function's values as Metal hands them to its compiler: -[_MTLFunctionInternal specializationAirScript],
 * a FlatBuffers buffer with the file identifier "AIRC" (MTLFunctionConstantValuesInternal's newConstantScriptForFunction:
 * makes it). Read off the bytes of CoreAnimation's own functions on the phone, not a published schema: the root's
 * third field a table whose first field is the function's name and whose third a vector of tables, one per constant,
 * each with the constant's index (u16, field 0, absent for 0), its MTLDataType (a byte, field 1) and, at the forward
 * offset in field 2, the value's bytes. Every offset is checked against the size; a buffer that does not hold together
 * gives no constants, and says so. */
static unsigned hm_function_constants_declared(id function, hakios_metal_constant *out, unsigned max);

static unsigned
hm_script_constants(const uint8_t *b, size_t size, hakios_metal_constant *out, unsigned max)
{
#define HM_FITS(o, n) ((uint64_t)(o) + (n) <= size)
	uint32_t root, sub, vec, n, count = 0;

	if (size < 8 || memcmp(b + 4, "AIRC", 4) != 0) {
		return 0;
	}
	/* field K of the table at T: its absolute position, or 0 when absent */
	uint64_t (^field)(uint64_t, unsigned) = ^uint64_t(uint64_t t, unsigned k) {
		int32_t so;
		uint64_t vt;
		uint16_t vlen, off;

		if (!HM_FITS(t, 4)) return 0;
		memcpy(&so, b + t, 4);
		vt = t - (int64_t)so;
		if (!HM_FITS(vt, 4)) return 0;
		memcpy(&vlen, b + vt, 2);
		if (4 + 2 * k + 2 > vlen || !HM_FITS(vt + 4 + 2 * k, 2)) return 0;
		memcpy(&off, b + vt + 4 + 2 * k, 2);
		return off != 0 ? t + off : 0;
	};
	/* the forward offset stored at position P, followed */
	uint64_t (^follow)(uint64_t) = ^uint64_t(uint64_t p) {
		uint32_t o;

		if (p == 0 || !HM_FITS(p, 4)) return 0;
		memcpy(&o, b + p, 4);
		return HM_FITS(p + o, 1) ? p + o : 0;
	};
	memcpy(&root, b, 4);
	sub = (uint32_t)follow(field(root, 2));
	vec = sub != 0 ? (uint32_t)follow(field(sub, 2)) : 0;
	if (vec == 0 || !HM_FITS(vec, 4)) {
		HM_ONCE("a specialization script that does not hold together (%zu bytes): its function is compiled with no constants\n", size);
		return 0;
	}
	memcpy(&n, b + vec, 4);
	for (uint32_t e = 0; e < n && count < max && HM_FITS(vec + 4 + 4 * e, 4); e++) {
		uint64_t et = follow(vec + 4 + 4 * e), fi, ft, fv;
		uint16_t index = 0;
		unsigned bytes;

		if (et == 0) break;
		fi = field(et, 0);
		ft = field(et, 1);
		fv = follow(field(et, 2));
		if (ft == 0 || fv == 0) continue;
		if (fi != 0 && HM_FITS(fi, 2)) memcpy(&index, b + fi, 2);
		bytes = hm_data_type_bytes((MTLDataType)b[ft]);
		if (bytes == 0 || !HM_FITS(fv, bytes)) continue;
		out[count].index = index;
		out[count].bits = 0;
		memcpy(&out[count].bits, b + fv, bytes);
		count++;
	}
	return count;
#undef HM_FITS
}

/* The values from the script; when there is none, or it gave nothing although the function declares constants, from
 * the declared constants and the base values (the same answer by Metal's other road). */
static unsigned
hm_function_constants(id function, hakios_metal_constant *out, unsigned max)
{
	SEL scriptSel = sel_getUid("specializationAirScript");

	if (function != nil && [function respondsToSelector:scriptSel]) {
		dispatch_data_t script = ((dispatch_data_t(*)(id, SEL))objc_msgSend)(function, scriptSel);

		if (script != nil) {
			const void *bytes = NULL;
			size_t size = 0;
			dispatch_data_t map = dispatch_data_create_map(script, &bytes, &size);
			unsigned n = hm_script_constants((const uint8_t *)bytes, size, out, max);

			dispatch_release(map);
			HM_ONCE("function constants: %s was specialised by a script of %zu bytes giving %u values (the first such function)\n",
				[[function name] UTF8String], size, n);
			if (n != 0) {
				return n;
			}
		}
	}
	return hm_function_constants_declared(function, out, max);
}

static unsigned
hm_function_constants_declared(id function, hakios_metal_constant *out, unsigned max)
{
	SEL baseSel = sel_getUid("baseFunctionConstantValues"), valueSel = sel_getUid("constantValueWithFunctionConstant:");
	NSDictionary *declared;
	id values;
	unsigned n = 0;

	if (function == nil || ![function respondsToSelector:@selector(functionConstantsDictionary)] || ![function respondsToSelector:baseSel]) {
		return 0;
	}
	declared = [function functionConstantsDictionary];
	values = ((id(*)(id, SEL))objc_msgSend)(function, baseSel);
	if ([declared count] == 0 || values == nil || ![values respondsToSelector:valueSel]) {
		return 0;
	}
	for (NSString *name in declared) {
		MTLFunctionConstant *c = [declared objectForKey:name];
		const void *v = ((const void *(*)(id, SEL, id))objc_msgSend)(values, valueSel, c);
		unsigned bytes = hm_data_type_bytes([c type]);

		if (v == NULL || bytes == 0 || n >= max) {
			continue;
		}
		out[n].index = (unsigned)[c index];
		out[n].bits = 0;
		memcpy(&out[n].bits, v, bytes);
		n++;
	}
	HM_ONCE("function constants: %s declares %lu and was given %u of them (the first function seen with constants)\n",
		[[function name] UTF8String], (unsigned long)[declared count], n);
	return n;
}

/*
 * Whether FUNCTION, as CoreAnimation specialised it, is compiled exactly from AIR (the module that is going to be
 * compiled: the function's bitcodeData) with the COUNT values read above. nil when it is; otherwise the precise reason.
 * What the AIR declares is read off the AIR itself (hakios_metal_bitcode_function_constants), not off the function:
 * Metal reports no functionConstantsDictionary for a function it has specialised.
 *   - the AIR declares constants and no value arrived (Metal dropped them, or the script was not read);
 *   - a value arrived for an index the AIR does not declare (the values are another function's);
 *   - an uber shader (fixed_*) whose AIR declares no constants and for which Metal recorded nothing: the library's
 *     function is a pipelinelib variant, not iOS 16.5's generic one, and CoreAnimation's named values were dropped.
 * AIR that declares no constants while values were recorded is Metal's own specialisation, compiled as it is.
 * Constants CoreAnimation did not set stay undefined, as Apple's compiler leaves them; a required one Metal itself
 * refuses to make a function without.
 */
static NSString *
hm_ca_exact_why_not(id function, NSData *air, const hakios_metal_constant *values, unsigned count)
{
	unsigned declared[128];

	if (function == nil) {
		return nil;   /* the built-in fragment function */
	}
	NSString *name = [function name];
	unsigned n = hakios_metal_bitcode_function_constants([air bytes], [air length], declared, 128);

	if (n == 0) {
		if ([name hasPrefix:@"fixed_"] && count == 0) {
			return [NSString stringWithFormat:@"%@'s AIR declares no function constants and Metal recorded no values for it: the "
				"library's %@ is a pipelinelib variant, not iOS 16.5's generic one, so the named values CoreAnimation passed were "
				"dropped (ca-share must be iOS 16.5's own QuartzCore default.metallib: tools/ca-metallib.py)", name, name];
		}
		return nil;
	}
	if (count == 0) {
		return [NSString stringWithFormat:@"%@'s AIR declares %u function constants and no value for any of them was read "
			"(specializationAirScript and baseFunctionConstantValues gave none)", name, n];
	}
	for (unsigned i = 0; i < count; i++) {
		BOOL known = NO;

		for (unsigned j = 0; j < n && j < 128 && !known; j++) known = declared[j] == values[i].index;
		if (!known) {
			return [NSString stringWithFormat:@"%@ was handed a value for function constant %u, which its AIR (%u constants) "
				"does not declare", name, values[i].index, n];
		}
	}
	return nil;
}
