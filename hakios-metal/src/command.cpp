#include "hakios-metal/command.hpp"
#include "hakios-metal/perf.h"
#include "hakios-metal/texture.hpp"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <map>
#include <mutex>
#include <cstdio>
#include <cstring>
#include <unistd.h>

namespace hakios::metal {

namespace {
constexpr size_t kCommandBo = 64 * 1024;           // one command buffer's packets, at most (grown when needed)
constexpr int64_t kPatienceNs = 5000000000;        // a fence not passed in 5 s: the GPU is hung, the buffer is an error
constexpr uint32_t kFillHead = 64;                 // words written by CP_MEM_WRITE before the copies double them
// The most one CP_MEMCPY moves. On the phone (27 October) 125 000 words in one packet took 4.2 ms, and 4 Mi words (16 MB)
// in one packet hung the GPU ("no answer" from the kernel's driver, and the system after it). Cut into packets of this
// size, each waited for before the next, the same copy is a row of small ones.
constexpr uint32_t kMemcpyMax = 64 * 1024;
}  // namespace

void appendStream(pm4::Stream& to, const pm4::Stream& from);   // render.cpp's: a pass of its own onto the buffer's stream

namespace {
std::mutex gSubmissionLock;
std::vector<CommandQueue*> gQueues;
std::mutex gAddressLock;
std::map<uint64_t, std::weak_ptr<Buffer>> gByAddress;   // by gpuAddress, every Buffer newBuffer made and still alive

std::shared_ptr<Buffer> addressed(Buffer* raw) {
    const uint64_t at = raw->gpuAddress();
    std::shared_ptr<Buffer> b(raw, [at](Buffer* x) {
        {
            std::lock_guard<std::mutex> g(gAddressLock);
            auto it = gByAddress.find(at);
            if (it != gByAddress.end() && it->second.expired()) gByAddress.erase(it);
        }
        delete x;
    });
    std::lock_guard<std::mutex> g(gAddressLock);
    gByAddress[at] = b;
    return b;
}
}  // namespace

std::shared_ptr<Buffer> bufferAt(uint64_t address, uint64_t* offset) {
    std::lock_guard<std::mutex> g(gAddressLock);
    auto it = gByAddress.upper_bound(address);
    if (it == gByAddress.begin()) return nullptr;
    --it;
    std::shared_ptr<Buffer> b = it->second.lock();
    if (b == nullptr || address - it->first >= b->length()) return nullptr;
    *offset = address - it->first;
    return b;
}

std::atomic<uint32_t> gBuffersMade{0}, gBuffersReused{0};
std::atomic<uint32_t> gLongestStream{0}, gStreamsCut{0};   // hakios_metal_stream_counts'
std::atomic<uint64_t> gBytesMade{0};

std::shared_ptr<Buffer> newBuffer(Gpu& gpu, uint64_t length, std::string* why, uint32_t flags) {
    int error = 0;
    std::unique_ptr<Bo> bo = gpu.newBo(length, flags, &error);
    if (bo == nullptr) {
        *why = "the driver gave no buffer of " + std::to_string(length) + " bytes: " + strerror(error);
        return nullptr;
    }
    gBuffersMade++;
    gBytesMade += length;
    return addressed(new Buffer(std::move(bo), length));
}

namespace {
// One slab is 32 draw tables. Pieces are cut at 256 bytes, which is more than anything in them wants (128 for a
// program's preload and the border colour, 64 for a texture descriptor), and a piece of a page or more starts on a
// page, so that a table lies in memory as it did in a buffer of its own.
constexpr uint64_t kSlabBytes = 256 * 1024;
constexpr uint64_t kPieceAlign = 256;
constexpr uint64_t kPageAlign = 4096;
}  // namespace

bool CommandBuffer::piece(uint64_t bytes, Piece* out, std::string* why) {
    bytes = (std::max<uint64_t>(bytes, 1) + kPieceAlign - 1) & ~(kPieceAlign - 1);
    const uint64_t align = bytes >= kPageAlign ? kPageAlign : kPieceAlign;
    if (slab_ != nullptr) {
        slabUsed_ = std::min(kSlabBytes, (slabUsed_ + align - 1) & ~(align - 1));
    }
    if (bytes > kSlabBytes / 4) {
        // (a piece this large in a slab would leave most of the slab unused when the next one did not fit)
        out->buffer = queue_.takeBuffer(bytes, why);
        out->offset = 0;
        if (out->buffer != nullptr) slabs_.push_back(out->buffer);
    } else {
        if (slab_ == nullptr || kSlabBytes - slabUsed_ < bytes) {
            slab_ = queue_.takeSlab(kSlabBytes, why);
            slabUsed_ = 0;
            if (slab_ != nullptr) slabs_.push_back(slab_);
        }
        out->buffer = slab_;
        out->offset = slabUsed_;
        if (slab_ != nullptr) {
            slabUsed_ += bytes;
        }
    }
    if (out->buffer == nullptr) {
        return false;
    }
    if (out->offset == 0) {
        use(*out->buffer, true);
        keep(out->buffer);
    }
    return true;
}

uint64_t CommandBuffer::programAddress(const Kernel& k, std::string* why) {
    const uint32_t n = std::max<uint32_t>(k.numWords, 1);
    auto same = [&](const Uploaded& u) {
        if (u.words.size() != k.numWords) return false;
        for (uint32_t i = 0; i < k.numWords; i += 64) {
            if (u.words[i] != k.words[i]) return false;
        }
        return k.numWords == 0 || u.words.back() == k.words[k.numWords - 1];
    };
    const auto [first, last] = uploaded_.equal_range(k.words);
    for (auto it = first; it != last; ++it) {
        if (same(it->second)) return it->second.gpuAddress;
    }
    (void)n;
    std::shared_ptr<Buffer> b = queue_.programBuffer(k, why);
    if (b == nullptr) return 0;
    use(*b, false);
    keep(b);
    uploaded_.emplace(k.words, Uploaded{std::vector<uint32_t>(k.words, k.words + k.numWords), b->gpuAddress()});
    return b->gpuAddress();
}

namespace {
uint64_t sizeClass(uint64_t bytes) {
    uint64_t c = 4096;
    while (c < bytes) c <<= 1;
    return c;
}
}  // namespace

std::shared_ptr<Buffer> CommandQueue::takeBuffer(uint64_t bytes, std::string* why) {
    auto mark = hm_perf_begin();
    const uint64_t size = sizeClass(bytes);
    std::shared_ptr<Buffer> b;
    {
        std::lock_guard<std::mutex> g(poolLock_);
        auto it = freeBuffers_.find(size);
        if (it != freeBuffers_.end() && !it->second.empty()) {
            b = std::move(it->second.back());
            it->second.pop_back();
            freeBytes_ -= size;
        }
    }
    if (b == nullptr) {
        hm_perf_end(HM_PERF_POOL_MISS, mark, size);
        return newBuffer(gpu_, size, why);
    }
    gBuffersReused++;
    memset(b->contents(), 0, size);   // (as a new one comes from the kernel)
    hm_perf_end(HM_PERF_POOL_HIT, mark, size);
    return b;
}

void CommandQueue::giveBuffer(std::shared_ptr<Buffer> b) {
    // (only one no one else holds, of a size takeBuffer makes: a piece's buffer kept elsewhere is still someone's)
    if (b == nullptr || b.use_count() != 1 || b->contents() == nullptr || b->length() != sizeClass(b->length())) return;
    std::lock_guard<std::mutex> g(poolLock_);
    if (freeBytes_ + b->length() > (32ull << 20)) return;
    freeBytes_ += b->length();
    freeBuffers_[b->length()].push_back(std::move(b));
}

std::shared_ptr<Buffer> CommandQueue::takeSlab(uint64_t bytes, std::string* why) { return takeBuffer(bytes, why); }

void CommandQueue::giveSlabs(std::vector<std::shared_ptr<Buffer>>* slabs) {
    for (auto& b : *slabs) giveBuffer(std::move(b));
    slabs->clear();
}

std::shared_ptr<Buffer> CommandQueue::programBuffer(const Kernel& k, std::string* why) {
    std::lock_guard<std::mutex> g(lock_);
    const auto [first, last] = resident_.equal_range(k.words);
    for (auto it = first; it != last;) {
        const Resident& r = it->second;
        if (r.words.size() == k.numWords && std::memcmp(r.words.data(), k.words, 4ull * k.numWords) == 0) return r.buffer;
        residentBytes_ -= 4ull * r.words.size();
        it = resident_.erase(it);   // (the pointer's words have changed: a freed program's)
    }
    // (past 64 MB of programs, the ones kept are let go: a command buffer in flight keeps its own)
    if (residentBytes_ > (64ull << 20)) {
        resident_.clear();
        residentBytes_ = 0;
    }
    std::shared_ptr<Buffer> b = newBuffer(gpu_, 4ull * std::max<uint32_t>(k.numWords, 1), why);
    if (b == nullptr || b->contents() == nullptr) return nullptr;
    memcpy(b->contents(), k.words, 4ull * k.numWords);
    resident_.emplace(k.words, Resident{std::vector<uint32_t>(k.words, k.words + k.numWords), b});
    residentBytes_ += 4ull * k.numWords;
    return b;
}

namespace {
// A weak pointer expires BEFORE its deleter takes this lock. Keep the entry until the kernel handle is
// closed, and wait for that close before importing again. Key by surface ID so this check precedes the ioctl.
std::mutex gSurfaceLock;
std::condition_variable gSurfaceClosed;
struct SurfaceBufferEntry {
    std::weak_ptr<Buffer> buffer;
    SurfaceInfo info;
};
std::map<std::pair<const Gpu*, uint32_t>, SurfaceBufferEntry> gSurfaceBuffers;
}  // namespace

std::shared_ptr<Buffer> surfaceBuffer(Gpu& gpu, uint32_t surfaceId, SurfaceInfo* info, std::string* why) {
    std::unique_lock<std::mutex> g(gSurfaceLock);
    const auto key = std::make_pair(static_cast<const Gpu*>(&gpu), surfaceId);
    for (;;) {
        auto live = gSurfaceBuffers.find(key);
        if (live == gSurfaceBuffers.end()) break;
        if (auto b = live->second.buffer.lock()) {
            *info = live->second.info;
            return b;
        }
        gSurfaceClosed.wait(g);  // releases the lock so the expired Buffer's deleter can close its handle
    }
    int error = 0;
    std::unique_ptr<Bo> bo = gpu.surfaceBo(surfaceId, info, &error);
    if (bo == nullptr) {
        *why = "IOSurface " + std::to_string(surfaceId) + ": the driver gave no buffer for it: " +
               (error == ENOENT ? std::string("no such surface") : error == ENOTSUP ? std::string("a surface around a program's own memory is not one the GPU takes") : strerror(error));
        return nullptr;
    }
    const uint64_t length = bo->size();
    std::shared_ptr<Buffer> b(new Buffer(std::move(bo), length, surfaceId), [key](Buffer* x) {
        std::lock_guard<std::mutex> g(gSurfaceLock);
        delete x;
        gSurfaceBuffers.erase(key);
        gSurfaceClosed.notify_all();
    });
    gSurfaceBuffers[key] = {b, *info};
    return b;
}

int synchronizeSurface(uint32_t surfaceId) {
    std::vector<std::shared_ptr<Buffer>> buffers;
    {
        std::lock_guard<std::mutex> g(gSurfaceLock);
        for (const auto& entry : gSurfaceBuffers)
            if (entry.first.second == surfaceId)
                if (auto b = entry.second.buffer.lock()) buffers.push_back(std::move(b));
    }
    for (const auto& b : buffers) {
        int e = CommandQueue::synchronize(b->bo());
        if (e) return e;
    }
    return 0;
}

// --- CommandBuffer ----------------------------------------------------------------------------------------------

bool CommandBuffer::fail(const std::string& why) {
    if (error_.empty()) {
        error_ = why;
    }
    return false;
}

void CommandBuffer::stamp(uint32_t slot) {
    const uint32_t block = slot / (2 * kProfilePassesPerBlock);
    if (block == ownProfileStamps_.size()) {
        std::string why;
        auto buffer = queue_.takeBuffer(16 * kProfilePassesPerBlock, &why);
        if (buffer == nullptr) {
            // said once a process: a pool with no stamp buffer failed the timing of every buffer after it, and a silent
            // -profile_ left a pass summary that never named a pass (Maps asked for 1,001 buffers in 2 s)
            static std::atomic<bool> said{false};
            if (!said.exchange(true)) {
                fprintf(stderr, "profile: the stamps' buffer could not be taken (%s); buffers are not timed from here\n", why.c_str());
            }
            profile_ = tuning_ = false;
            return;
        }
        memset(buffer->contents(), 0, 16 * kProfilePassesPerBlock);
        keep(buffer);
        ownProfileStamps_.push_back(std::move(buffer));
    }
    const auto& buffer = ownProfileStamps_[block];
    const uint64_t at = buffer->gpuAddress() + 8ull * (slot % (2 * kProfilePassesPerBlock));
    const uint32_t w[3] = {a6xx::CP_REG_TO_MEM_0_REG(0x0980) | a6xx::CP_REG_TO_MEM_0_CNT(2) | a6xx::CP_REG_TO_MEM_0_64B, uint32_t(at),
                           uint32_t(at >> 32)};
    stream_.packet(a6xx::CP_REG_TO_MEM, w, 3);
    use(*buffer, true);
}

std::shared_ptr<Buffer> CommandQueue::vscBuffer(std::string* why) {
    std::lock_guard<std::mutex> g(lock_);
    if (vsc_ == nullptr) vsc_ = newBuffer(gpu_, render::vscBytes(), why);
    return vsc_;
}

std::shared_ptr<Buffer> CommandQueue::gmemTrace(std::string* why) {
    std::lock_guard<std::mutex> g(lock_);
    if (gmemTrace_ == nullptr) gmemTrace_ = newBuffer(gpu_, 4096, why);
    return gmemTrace_;
}

void CommandQueue::checkVsc() {
    std::lock_guard<std::mutex> g(lock_);
    if (vsc_ == nullptr || vsc_->contents() == nullptr) return;
    const uint32_t word = *reinterpret_cast<const volatile uint32_t*>(static_cast<const uint8_t*>(vsc_->contents()) + 32ull * render::kVscDrawPitch + render::kVscOverflowAt);
    if (word != 0) vscOverflowed_ = true;
}

bool CommandQueue::preferGmem(uint64_t key) {
    std::lock_guard<std::mutex> g(lock_);
    Tune& t = tune_[key];
    t.passes++;
    // (sysmem first: a kind of pass seen once may not come again, and an untried GMEM pass is the dearer gamble -- 5 ms
    // against 0.13 for a light one)
    if (t.runs[0] == 0) return false;
    if (t.runs[1] == 0) return true;
    const bool better = t.us[1] < t.us[0];
    // (the other mode again now and then, what a pass costs drifting: every 16th pass, or every 64th when the one is
    // dearer by half -- a light pass of CoreAnimation took 5 ms in GMEM against 0.13 in sysmem)
    const double ratio = better ? t.us[0] / t.us[1] : t.us[1] / t.us[0];
    return t.passes % (ratio > 1.5 ? 64 : 16) == 0 ? !better : better;
}

namespace {
uint64_t kindKey(uint64_t kind, uint32_t ordinal) { return kind * 0x100000001b3ull ^ ordinal; }
}  // namespace

uint32_t CommandQueue::lastDraws(uint64_t kind, uint32_t ordinal) {
    std::lock_guard<std::mutex> g(lock_);
    auto it = lastDraws_.find(kindKey(kind, ordinal));
    return it == lastDraws_.end() ? 0 : it->second;
}

void CommandQueue::noteDraws(uint64_t kind, uint32_t ordinal, uint32_t draws) {
    std::lock_guard<std::mutex> g(lock_);
    lastDraws_[kindKey(kind, ordinal)] = draws;
    Peak& p = peakDraws_[kindKey(kind, ordinal)];
    if (draws >= p.draws || ++p.below >= 16) p.draws = draws, p.below = 0;
}

uint32_t CommandQueue::peakDraws(uint64_t kind, uint32_t ordinal) {
    std::lock_guard<std::mutex> g(lock_);
    auto it = peakDraws_.find(kindKey(kind, ordinal));
    return it == peakDraws_.end() ? 0 : it->second.draws;
}

void CommandQueue::tuned(uint64_t key, bool gmem, double us) {
    if (!(us > 0)) return;
    std::lock_guard<std::mutex> g(lock_);
    Tune& t = tune_[key];
    double& avg = t.us[gmem ? 1 : 0];
    avg = t.runs[gmem ? 1 : 0]++ == 0 ? us : 0.75 * avg + 0.25 * us;
}

void CommandBuffer::stampStart(PassKind kind, uint32_t width, uint32_t height) {
    if (!(profile_ || tuning_)) return;
    PassTime t{}; t.kind = kind, t.width = width, t.height = height; t.wordBegin = streamWords();
    // (this buffer's own passes, not profiled_'s: append() merges a sub-buffer's passes into that vector afterwards)
    const uint32_t slot = uint32_t(2 * ownPasses_);
    stamp(slot);
    if (profile_ || tuning_) {
        // (which buffer and slots the stamps went to: append() moves the buffer, so the entry keeps the buffer, not an index)
        const uint32_t block = slot / uint32_t(2 * kProfilePassesPerBlock);
        if (block < ownProfileStamps_.size()) {
            t.stampBuffer = ownProfileStamps_[block].get();
            t.stampSlot = slot % (2 * kProfilePassesPerBlock);
        }
        profiled_.push_back(std::move(t));
        ownPasses_++;
    }
}

void CommandBuffer::stampEnd() {
    if (!(profile_ || tuning_) || ownPasses_ == 0) return;
    stamp(uint32_t(2 * (ownPasses_ - 1) + 1));
    if (profiled_.empty()) return;
    PassTime& t = profiled_.back();
    t.wfis = countWfis(stream_.words().data() + t.wordBegin, streamWords() - t.wordBegin);
}

const Buffer* CommandBuffer::drawStamp(uint32_t slot) {
    if (drawStamps_ == nullptr) {
        std::string why;
        drawStamps_ = queue_.takeBuffer(16 * kMaxProfiledDraws, &why);
        if (drawStamps_ == nullptr) {
            profileDraws_ = false;
            return nullptr;
        }
        memset(drawStamps_->contents(), 0, 16 * kMaxProfiledDraws);
        keep(drawStamps_);
        drawStampBuffers_.push_back(drawStamps_);
    }
    const uint64_t at = drawStamps_->gpuAddress() + 8ull * slot;
    stream_.waitForIdle();
    const uint32_t w[3] = {a6xx::CP_REG_TO_MEM_0_REG(0x0980) | a6xx::CP_REG_TO_MEM_0_CNT(2) | a6xx::CP_REG_TO_MEM_0_64B, uint32_t(at),
                           uint32_t(at >> 32)};
    stream_.packet(a6xx::CP_REG_TO_MEM, w, 3);
    use(*drawStamps_, true);
    return drawStamps_.get();
}

std::vector<CommandBuffer::DrawTime> CommandBuffer::drawTimes() const {
    std::vector<DrawTime> out = drawsProfiled_;
    for (DrawTime& d : out) {
        if (d.stampBuffer == nullptr) continue;
        const auto* t = static_cast<const uint64_t*>(d.stampBuffer->contents());
        d.us = t[d.stampSlot + 1] > t[d.stampSlot] ? double(t[d.stampSlot + 1] - t[d.stampSlot]) / 19.2 : 0.0;
    }
    return out;
}

std::vector<CommandBuffer::PassTime> CommandBuffer::passTimes() const {
    std::vector<PassTime> out = profiled_;
    for (PassTime& t : out) {
        if (t.stampBuffer == nullptr) continue;
        const auto* s = static_cast<const uint64_t*>(t.stampBuffer->contents());
        t.us = s[t.stampSlot + 1] > s[t.stampSlot] ? double(s[t.stampSlot + 1] - s[t.stampSlot]) / 19.2 : 0.0;
    }
    return out;
}

// Names in one pass share one GPU interval; GMEM shaders are not individually timed.
// Every signature in the two-second window is reported, without a lifetime log budget.
void CommandBuffer::reportPasses() const {
    struct Total { uint64_t count = 0, draws = 0, wfis = 0, resolves = 0, profileWfis = 0, fetch = 0, rawBarriers = 0;
                   uint32_t clearQuads = 0, clearFull = 0; uint64_t clearQuadPixels = 0;
                   // v29i (P1): the clear quads the 2D engine's fill wrote (render::clearQuadFillMask) and those it did not
                   uint32_t clearQuadFills = 0, clearQuadFallbacks = 0;
                   double us = 0, maxUs = 0;
                   // v29i (D1): the pass's row bands and what it sampled unwritten, and what names it here
                   uint32_t kind = 0, width = 0, height = 0, loads = 0, stores = 0, targetSurface = 0, neverWrittenDraws = 0;
                   uint16_t bands = 0, bandsNoClear = 0;
                   PassTime::Sampled examples[3]; uint8_t exampleCount = 0; };
    static std::mutex mutex;
    static std::map<std::string, Total> totals;
    static uint64_t began = 0;
    const uint64_t now = queue_.gpu_.transport().nowNs();
    std::lock_guard<std::mutex> guard(mutex);
    if (began == 0) began = now;
    for (const PassTime& t : passTimes()) {
        std::string names;
        for (const std::string& shader : t.shaders) { if (!names.empty()) names += ","; names += shader; }
        std::string key = "kind=" + std::to_string(t.kind) + " size=" + std::to_string(t.width) + "x" + std::to_string(t.height) +
            " mode=" + (t.tiles ? "gmem" : "sysmem") + " tiles=" + std::to_string(t.tiles) + " samples=" + std::to_string(t.samples) +
            " load=" + std::to_string(t.loads) + " store=" + std::to_string(t.stores) + " clear=" + std::to_string(t.clears) +
            " fmt=[" + t.attachedFmt + "] shaders=[" + names + "] why=[" + t.sysmemWhy + "]";
        Total& sum = totals[key];
        sum.count++; sum.draws += t.draws; sum.wfis += t.wfis; sum.resolves += t.resolves; sum.profileWfis += t.profileWfis;
        sum.fetch += t.fetchDraws; sum.rawBarriers += t.inPassBarriers;
        sum.clearQuads += t.clearQuadDraws; sum.clearFull += t.clearQuadFull; sum.clearQuadPixels += t.clearQuadPixels;
        sum.clearQuadFills += t.clearQuadFills; sum.clearQuadFallbacks += t.clearQuadFallbacks;
        sum.us += t.us; sum.maxUs = std::max(sum.maxUs, t.us);
        if (sum.count == 1) sum.kind = t.kind, sum.width = t.width, sum.height = t.height, sum.loads = t.loads, sum.stores = t.stores;
        sum.bands |= t.bands; sum.bandsNoClear |= t.bandsNoClear;
        sum.neverWrittenDraws += t.neverWrittenDraws;
        if (sum.targetSurface == 0) sum.targetSurface = t.targetSurface;
        for (uint8_t e = 0; e < t.neverWrittenCount && sum.exampleCount < 3; e++) sum.examples[sum.exampleCount++] = t.neverWritten[e];
    }
    if (now - began < 2000000000ull) return;
    for (const auto& [key, sum] : totals) {
        fprintf(stderr, "pass-v29d: pid=%d window_ms=%.1f %s count=%llu gpu_ms=%.3f max_ms=%.3f draws=%llu wfi=%llu resolve_ops=%llu profile_wfi=%llu fetch=%llu rawBarrier=%llu clearQuad=%u clearFull=%u clearQuadPx=%llu clearQuadFill=%u clearQuadFallback=%u\n",
            getpid(), double(now - began) / 1e6, key.c_str(), (unsigned long long)sum.count, sum.us / 1e3, sum.maxUs / 1e3,
            (unsigned long long)sum.draws, (unsigned long long)sum.wfis, (unsigned long long)sum.resolves, (unsigned long long)sum.profileWfis,
            (unsigned long long)sum.fetch, (unsigned long long)sum.rawBarriers, sum.clearQuads, sum.clearFull,
            (unsigned long long)sum.clearQuadPixels, sum.clearQuadFills, sum.clearQuadFallbacks);
    }
    /* v29i (D1): one line a window, for the pass family the window spent most of its GPU time in -- the pass the
     * App Library's black is in (work/v29i/INVESTIGATION-applibrary-black-2.md, D1). Rows: 16 bands of the target,
     * bit 0 the top (row * 16 / height). COVER: a band some draw's viewport and scissor reached (render::drawArea, so
     * an upper bound: a clear quad's geometry is not looked at). NOCLEAR: the same without CoreAnimation's
     * attachment_clear_frag quads, whose area drawArea reads as the whole target. NEVER-WRITTEN: draws that sampled a
     * texture no write had reached since it was made (texture.hpp: everWritten) -- a sampling of memory nothing filled,
     * black on a fresh allocation. Examples: size, IOSurface (0: its own memory) and resource id, up to three.
     * Bit tests and counters only: nothing here reads a texture back or logs a frame. */
    const Total* largest = nullptr;
    bool anyDraw = false;
    for (const auto& [key, sum] : totals) anyDraw = anyDraw || sum.kind == kPassDraw;
    for (const auto& [key, sum] : totals) {
        // (a draw pass where there is one: a copy pass records no bands -- its destination is its whole target)
        if (anyDraw && sum.kind != kPassDraw) continue;
        if (largest == nullptr || sum.us > largest->us || (sum.us == largest->us && uint64_t(sum.width) * sum.height > uint64_t(largest->width) * largest->height)) {
            largest = &sum;
        }
    }
    if (largest != nullptr && largest->count != 0) {
        char cover[17], noClear[17], examples[160] = {0};
        for (uint32_t b = 0; b < 16; b++) {
            cover[b] = (largest->bands >> b) & 1 ? 'X' : '.';
            noClear[b] = (largest->bandsNoClear >> b) & 1 ? 'X' : '.';
        }
        cover[16] = noClear[16] = 0;
        size_t at = 0;
        for (uint8_t e = 0; e < largest->exampleCount; e++) {
            const PassTime::Sampled& x = largest->examples[e];
            if (at >= sizeof(examples) - 1) break;
            const int wrote = snprintf(examples + at, sizeof(examples) - at, "%s%ux%u/s%u/id%llu", e == 0 ? "" : ",", x.width, x.height,
                                       x.surface, (unsigned long long)x.id);
            if (wrote <= 0) break;
            at += size_t(wrote);
        }
        char tail[200] = {0};
        if (at != 0) snprintf(tail, sizeof tail, " examples=%.*s", int(at), examples);
        fprintf(stderr, "pass-d1: pid=%d window_ms=%.1f size=%ux%u load=%u store=%u count=%llu gpu_ms=%.3f target=%s%u cover=%s noclear=%s "
                        "never-written-draws=%u%s\n",
                getpid(), double(now - began) / 1e6, largest->width, largest->height, largest->loads, largest->stores,
                (unsigned long long)largest->count, largest->us / 1e3, largest->targetSurface != 0 ? "surface" : "texture",
                largest->targetSurface, cover, noClear, largest->neverWrittenDraws, tail);
    }
    totals.clear(); began = now;
}

bool CommandBuffer::refuseWork(const std::string& why) {
    if (!skipRefused_) {
        return fail(why);
    }
    skipped_++;
    lastSkipped_ = why;
    return false;
}

void CommandBuffer::addCompletedHandler(std::function<void(CommandBuffer&)> handler) {
    if (status_ <= kEnqueued) {
        handlers_.push_back(std::move(handler));
    }
}

void CommandBuffer::enqueue() {
    Status expected = kNotEnqueued;
    status_.compare_exchange_strong(expected, kEnqueued);
}

void CommandBuffer::commit() {
    if (status_ > kEnqueued) {
        return;  // Metal asserts here; committing twice does nothing at all in this driver
    }
    queue_.submit(shared_from_this());
}

void CommandBuffer::waitUntilCompleted() {
    queue_.drain(CommandQueue::kCpuSync);
    std::unique_lock<std::mutex> g(lock_);
    // (a buffer never committed is not waited for: Metal would wait forever, which helps nobody)
    done_.wait(g, [this] { return finished_ || status_ <= kEnqueued; });
}

CommandBuffer::~CommandBuffer() {
    // (a buffer never completed may be destroyed with the GPU still on it -- an error -- and its stamps are then not
    // given back; one that completed has had its readers)
    if (finished_) {
        for (auto& buffer : ownProfileStamps_) queue_.giveBuffer(std::move(buffer));
        for (auto& buffer : profileStamps_) queue_.giveBuffer(std::move(buffer));
        // (its own draw stamps too: drawStampBuffers_ holds the only other reference, so giveBuffer would refuse the
        // second one and the buffer would be freed instead of pooled -- an 8 KiB allocation a profiled buffer)
        drawStamps_.reset();
        for (auto& buffer : drawStampBuffers_) queue_.giveBuffer(std::move(buffer));
    }
}

void CommandBuffer::inheritSettings(const CommandBuffer& parent) {
    skipRefused_ = parent.skipRefused_;
    profile_ = parent.profile_;
    profileDraws_ = parent.profileDraws_;
    gmem_ = parent.gmem_;
    gmemOff_ = parent.gmemOff_;
    gmemMinDraws_ = parent.gmemMinDraws_;
    adaptive_ = parent.adaptive_;
    gmemBinning_ = parent.gmemBinning_;
    gmemMsaaZs_ = parent.gmemMsaaZs_;
    nullFsTextures_ = parent.nullFsTextures_;
    passWfi_ = parent.passWfi_;
    tuning_ = parent.tuning_;
}

void CommandBuffer::finish(Status s) {
    status_ = s;
    if (s == kCompleted && profile_) {
        if (profiled_.empty() && counts_.passes != 0) {
            // one line a process: passes were recorded into this buffer and none is described, which is a summary that
            // can only say "nothing" -- the stamp buffer's own failure is said in stamp(), this is the other way here
            static std::atomic<bool> said{false};
            if (!said.exchange(true)) {
                fprintf(stderr, "profile: a buffer of %u passes has none timed (no stamps taken)\n", counts_.passes);
            }
        }
        reportPasses();
    }
    if (s == kCompleted && counts_.binnedPasses != 0) queue_.checkVsc();
    if (s == kCompleted && tuning_) {
        for (const PassTime& t : passTimes()) {
            if (t.tuneKey != 0) queue_.tuned(t.tuneKey, t.tiles != 0, t.us);
        }
    }
    for (auto& h : handlers_) {
        h(*this);
    }
    handlers_.clear();
    kept_.clear();
    slab_.reset();
    queue_.giveSlabs(&slabs_);   // (done with: the GPU has finished with this buffer, or never had it)
    keptAny_.clear();
    {
        std::lock_guard<std::mutex> g(lock_);
        finished_ = true;
    }
    done_.notify_all();
}

bool CommandBuffer::copy(const Buffer& from, uint64_t fromOffset, const Buffer& to, uint64_t toOffset, uint64_t length) {
    closePass();
    if (status_ > kEnqueued) {
        return fail("copy after commit");
    }
    if (fromOffset > from.length() || length > from.length() - fromOffset || toOffset > to.length() ||
        length > to.length() - toOffset) {
        return fail("copy outside a buffer");
    }
    if (length == 0) {
        return true;
    }
    if (fromOffset % 4 || toOffset % 4 || length % 4) {
        // the command processor moves words; a copy of bytes goes through the 2D engine instead (a pass of its own).
        // MapKit's snapshot service copies rows of 2 bytes into its textures.
        std::string why;
        Piece table;
        if (!piece(render::kTableBytes, &table, &why)) {
            return fail(std::string("no memory for the copy's table: ") + why);
        }
        pm4::Stream added;
        render::encodeBytes(added, from.gpuAddress() + fromOffset, to.gpuAddress() + toOffset, length, table.gpuAddress(), table.contents());
        appendStream(stream_, added);
        use(from, false);
        use(to, true);
        return true;
    }
    uint64_t words = length / 4, done = 0;
    while (done < words) {
        uint32_t n = uint32_t(std::min<uint64_t>(words - done, kMemcpyMax));
        stream_.memcpy(to.gpuAddress() + toOffset + 4 * done, from.gpuAddress() + fromOffset + 4 * done, n);
        // what comes after may read what this wrote: the copy lands before the next packet is taken
        stream_.waitMemWrites();
        stream_.waitForMe();
        done += n;
    }
    use(from, false);
    use(to, true);
    return true;
}

bool CommandBuffer::fill(const Buffer& b, uint64_t offset, uint64_t length, uint8_t value) {
    closePass();
    if (status_ > kEnqueued) {
        return fail("fill after commit");
    }
    if (offset % 4 || length % 4) {
        return fail("fill of " + std::to_string(length) + " bytes at " + std::to_string(offset) +
                    ": the command processor writes words, so both must be multiples of 4");
    }
    if (offset > b.length() || length > b.length() - offset) {
        return fail("fill outside the buffer");
    }
    if (length == 0) {
        return true;
    }
    uint32_t word = uint32_t(value) * 0x01010101u;
    uint64_t words = length / 4, base = b.gpuAddress() + offset;
    // the first words written as they are, ...
    uint32_t head = uint32_t(std::min<uint64_t>(words, kFillHead));
    std::vector<uint32_t> pattern(head, word);
    stream_.memWrite(base, pattern.data(), head);
    stream_.waitMemWrites();
    stream_.waitForMe();
    // ... and the rest copied from what is already filled, twice as much each time
    uint64_t have = head;
    while (have < words) {
        uint32_t n = uint32_t(std::min<uint64_t>(std::min<uint64_t>(have, words - have), kMemcpyMax));
        stream_.memcpy(base + 4 * have, base, n);
        stream_.waitMemWrites();
        stream_.waitForMe();
        have += n;
    }
    use(b, true);
    return true;
}

// --- CommandQueue -----------------------------------------------------------------------------------------------

std::unique_ptr<CommandQueue> CommandQueue::make(Gpu& gpu, std::string* why) {
    uint32_t id = 0;
    int e = gpu.newQueue(0, &id);
    if (e != 0) {
        *why = std::string("the driver gave no submission queue: ") + strerror(e);
        return nullptr;
    }
    std::unique_ptr<CommandQueue> q(new CommandQueue(gpu, id));
    {
        std::lock_guard<std::mutex> g(gSubmissionLock);
        gQueues.push_back(q.get());
    }
    q->thread_ = std::thread([p = q.get()] { p->waiter(); });
    return q;
}

CommandQueue::~CommandQueue() {
    {
        std::lock_guard<std::mutex> g(gSubmissionLock);
        drainLocked(kIdle);
        gQueues.erase(std::find(gQueues.begin(), gQueues.end(), this));
    }
    {
        std::lock_guard<std::mutex> g(lock_);
        quit_ = true;
    }
    changed_.notify_all();
    if (thread_.joinable()) {
        thread_.join();
    }
    idle_.clear();
    gpu_.closeQueue(id_);
}

std::shared_ptr<CommandBuffer> CommandQueue::commandBuffer() {
    return std::shared_ptr<CommandBuffer>(new CommandBuffer(*this));
}

std::shared_ptr<Texture> CommandQueue::nullTexture(std::string* why) {
    std::lock_guard<std::mutex> g(lock_);
    if (null_ == nullptr) {
        TextureDesc d;
        d.format = PixelFormat::kRGBA8Unorm;
        std::shared_ptr<Texture> t = Texture::make(gpu_, d, why);
        // (written, not taken as the kernel's fresh zeros: the zero is the claim, so it is put there in so many words)
        const uint32_t zero = 0;
        if (t == nullptr || !t->replace(0, 0, 1, 1, &zero, 4, why)) return nullptr;
        null_ = std::move(t);
    }
    return null_;
}

// The A650 has 3 SP cores (a6xx::kNumSpCores; freedreno_devices.py num_ccu 3): each spills at address + its index *
// TOTALPVTMEMSIZE, so the buffer holds all three (tu_setup_pvtmem). Sized for 2, the third SP wrote 2 MB past its end
// into freed or other buffers' addresses (v9: "SMMU REFUSED the 3D core ... allocator FREE", 32 KB-periodic, VTMTS).
std::shared_ptr<Buffer> CommandQueue::privateMemory(uint32_t bytes, bool perWave, PrivateMemory* out, std::string* why) {
    std::lock_guard<std::mutex> g(lock_);
    const int l = perWave ? 1 : 0;
    if (privatePerFiber_[l] < bytes) {
        uint32_t perFiber = 512;
        while (perFiber < bytes) perFiber *= 2;
        const uint64_t perSp = (uint64_t(perFiber) * a6xx::kFibersPerSp + 4095) & ~uint64_t(4095);
        std::shared_ptr<Buffer> b = newBuffer(gpu_, perSp * a6xx::kNumSpCores, why);
        if (b == nullptr) return nullptr;
        private_[l].push_back(std::move(b));
        privatePerFiber_[l] = perFiber;
    }
    const uint32_t perFiber = privatePerFiber_[l];
    out->address = private_[l].back()->gpuAddress();
    out->perFiber = perFiber;
    out->perSp = uint32_t((uint64_t(perFiber) * a6xx::kFibersPerSp + 4095) & ~uint64_t(4095));
    out->perWave = perWave;
    return private_[l].back();
}

size_t CommandQueue::idleCommandBuffers() {
    std::lock_guard<std::mutex> g(lock_);
    return idle_.size();
}

std::unique_ptr<Bo> CommandQueue::takeCommandBo(size_t bytes, int* error) {
    {
        std::lock_guard<std::mutex> g(lock_);
        for (auto it = idle_.begin(); it != idle_.end(); ++it) {
            if ((*it)->size() >= bytes) {
                std::unique_ptr<Bo> bo = std::move(*it);
                idle_.erase(it);
                return bo;
            }
        }
    }
    return gpu_.newBo(std::max(bytes, kCommandBo), kBoGpuReadOnly | kBoWriteCombined, error);
}

void CommandQueue::submit(std::shared_ptr<CommandBuffer> cb) {
    commitBatch({std::move(cb)});
}

uint32_t CommandBuffer::countWfis(const uint32_t* input, size_t size) const {
    std::unordered_map<uint64_t, uint32_t> ibWfis;
    std::function<uint32_t(const uint32_t*, size_t)> count = [&](const uint32_t* words, size_t size) {
        uint32_t n = 0;
        for (size_t i = 0; i < size;) {
            const auto h = pm4::decode(words[i]);
            if (h.kind == pm4::Header::kCommand) {
                if (h.opcode == pm4::kWaitForIdle) n++;
                if (h.opcode == pm4::kIndirectBuffer) {
                    const uint64_t at = words[i + 1] | uint64_t(words[i + 2]) << 32;
                    auto found = ibWfis.find(at);
                    if (found == ibWfis.end()) {
                        uint64_t offset;
                        auto buffer = bufferAt(at, &offset);
                        const uint32_t value = count(reinterpret_cast<const uint32_t*>(static_cast<const uint8_t*>(buffer->contents()) + offset), words[i + 3]);
                        found = ibWfis.emplace(at, value).first;
                    }
                    n += found->second;
                }
            }
            i += h.count + 1;
        }
        return n;
    };
    return count(input, size);
}

void CommandBuffer::prepareSubmission() {
    if (submissionPrepared_) return;
    submissionPrepared_ = true;
    committedAt_ = queue_.gpu_.transport().nowNs();
    if (error_.empty()) {
        auto mark = hm_perf_begin();
        closePass();
        stream_.waitMemWrites();
        stream_.waitForIdle();
        hm_perf_end(HM_PERF_CLOSE_PASS, mark, 0);
    }
    if (profile_ && error_.empty()) {
        counts_.wfis = countWfis(stream_.words().data(), streamWords());
    }
}

void CommandBuffer::use(const Buffer& b, bool write) {
    const uint8_t bit = write ? 2 : 1;
    uint8_t& seen = usedBos_[&b.bo()];
    if (seen & bit) return;
    int e = queue_.resolveUse(b.bo(), write);
    if (e) fail(std::string("cross-queue synchronization: ") + strerror(e));
    seen |= bit;
    uses_.push_back({&b.bo(), write});
}

// Submission and dependency decisions are serialized, never GPU completion callbacks.
int CommandQueue::synchronizeLocked(const Bo& bo, bool write, CommandQueue* consumer) {
    for (auto* q : gQueues) {
        if (q == consumer) continue;
        auto touches = [&](const std::shared_ptr<CommandBuffer>& cb) {
            for (const auto& use : cb->uses_)
                if (use.bo == &bo && (write || use.write)) return true;
            return false;
        };
        if (std::any_of(q->staged_.begin(), q->staged_.end(), touches))
            q->drainLocked(consumer ? kCrossQueue : kCpuSync);
        std::vector<uint32_t> fences;
        {
            std::lock_guard<std::mutex> g(q->lock_);
            for (const auto& cb : q->inFlight_)
                if (cb->status_ == CommandBuffer::kScheduled && touches(cb)) fences.push_back(cb->fence_);
        }
        // Wait for GPU memory visibility, not callbacks (which may themselves access this BO).
        for (auto fence : fences) {
            int e = q->gpu_.wait(q->id_, fence, kPatienceNs);
            if (e) return e;
        }
    }
    return 0;
}

int CommandQueue::resolveUse(const Bo& bo, bool write) {
    std::lock_guard<std::mutex> g(gSubmissionLock);
    return synchronizeLocked(bo, write, this);
}

int CommandQueue::synchronize(const Bo& bo, bool write) {
    std::lock_guard<std::mutex> g(gSubmissionLock);
    return synchronizeLocked(bo, write, nullptr);
}

bool CommandQueue::isComplete(const Bo& bo) {
    std::lock_guard<std::mutex> submission(gSubmissionLock);
    auto uses = [&](const std::shared_ptr<CommandBuffer>& cb) {
        return cb->status_ < CommandBuffer::kCompleted &&
            std::any_of(cb->uses_.begin(), cb->uses_.end(), [&](const BoUse& use) { return use.bo == &bo; });
    };
    for (auto* q : gQueues) {
        if (std::any_of(q->staged_.begin(), q->staged_.end(), uses)) return false;
        std::lock_guard<std::mutex> flight(q->lock_);
        if (std::any_of(q->inFlight_.begin(), q->inFlight_.end(), uses)) return false;
    }
    return true;
}

void CommandQueue::drainLocked(DrainReason reason) {
    if (staged_.empty()) return;
    auto buffers = std::move(staged_);
    staged_.clear();
    stagedWords_ = 0;
    submitBatch(buffers, reason);
}

void CommandQueue::drain(DrainReason reason) {
    std::lock_guard<std::mutex> g(gSubmissionLock);
    drainLocked(reason);
}

void CommandQueue::drainAll(DrainReason reason) {
    std::lock_guard<std::mutex> g(gSubmissionLock);
    for (auto* q : gQueues) q->drainLocked(reason);
}

void CommandQueue::stageBatch(const std::vector<std::shared_ptr<CommandBuffer>>& buffers, DrainReason reason) {
    for (const auto& cb : buffers) cb->prepareSubmission();
    std::lock_guard<std::mutex> g(gSubmissionLock);
    for (const auto& cb : buffers) {
        for (const auto& use : cb->uses_) {
            int e = synchronizeLocked(*use.bo, use.write, this);
            if (e) cb->refuse(std::string("cross-queue synchronization: ") + strerror(e));
        }
        const size_t words = cb->streamWords();
        if (!staged_.empty() && stagedWords_ + words + staged_.size() + 1 > 32768) drainLocked(kLimit);
        cb->status_ = CommandBuffer::kCommitted;
        staged_.push_back(cb);
        stagedWords_ += words;
        bool surface = false;
        for (const auto& b : cb->kept_) {
            auto use = cb->usedBos_.find(&b->bo());
            if (b->surface() && use != cb->usedBos_.end() && (use->second & 2)) surface = true;
        }
        if (surface || reason == kSurface) drainLocked(kSurface);
        else if (reason == kCpuSync || reason == kCrossQueue) drainLocked(reason);
        else if (staged_.size() == 8 || stagedWords_ + staged_.size() >= 32768) drainLocked(kLimit);
    }
}

void CommandQueue::commitBatch(const std::vector<std::shared_ptr<CommandBuffer>>& buffers) {
    for (const auto& cb : buffers) cb->prepareSubmission();
    std::unique_lock<std::mutex> g(gSubmissionLock);
    drainLocked(kCpuSync);
    for (const auto& cb : buffers)
        for (const auto& use : cb->uses_) {
            int e = synchronizeLocked(*use.bo, use.write, this);
            if (e) cb->refuse(std::string("cross-queue synchronization: ") + strerror(e));
        }
    submitBatch(buffers, kCpuSync, &g);
}

void CommandQueue::submitBatch(const std::vector<std::shared_ptr<CommandBuffer>>& buffers, DrainReason reason,
                               std::unique_lock<std::mutex>* submissionGuard) {
    HMPerfScope total(HM_PERF_SUBMIT);
    if (buffers.empty()) return;
    drainCounts_[reason]++;

    {
        std::lock_guard<std::mutex> g(lock_);
        if (buffers.front()->profile_) {
            encodeDrainReasons_[reason]++;
            encodeDrains_++;
            encodeDrainCbs_ += uint32_t(buffers.size());
            if (buffers.size() > 1) encodeBatchedCommits_ += uint32_t(buffers.size());
        }
        for (const auto& cb : buffers) {
            cb->status_ = CommandBuffer::kCommitted;
            ready_.push_back(cb);
        }
    }
    if (submissionGuard) submissionGuard->unlock();
    // The complete ready prefix is visible before the first submit. No timer and no unpublished fence on return.
    std::unique_lock<std::mutex> submitting(submitLock_);
    while (!buffers.back()->submissionResolved_) {
        std::vector<std::shared_ptr<CommandBuffer>> batch;
        {
            std::lock_guard<std::mutex> g(lock_);
            size_t words = 0;
            while (!ready_.empty() && batch.size() < 8) {
                const auto& next = ready_.front();
                const bool small = next->error_.empty() && next->streamWords() <= 8192 && next->counts_.draws <= 16;
                if (!batch.empty() && (!small || words + next->streamWords() + batch.size() + 1 > 32768)) break;
                words += next->streamWords();
                batch.push_back(next);
                ready_.pop_front();
                if (!small) break;
            }
        }
        auto& first = batch.front();
        if (!first->error_.empty()) {
            std::lock_guard<std::mutex> g(lock_);
            inFlight_.push_back(first);
            first->submissionResolved_ = true;
            changed_.notify_all();
            continue;
        }
        pm4::Stream combined;
        std::vector<BoUse> uses;
        std::unordered_map<const Bo*, uint8_t> seen;
        if (batch.size() > 1) for (const auto& part : batch) {
            appendStream(combined, part->stream_);
            for (const BoUse& use : part->uses_) {
                const uint8_t bit = use.write ? 2 : 1;
                uint8_t& bits = seen[use.bo];
                if (!(bits & bit)) { bits |= bit; uses.push_back(use); }
            }
        }
        const auto& w = batch.size() == 1 ? first->stream_.words() : combined.words();
        int error = 0;
        auto mark = hm_perf_begin();
        first->commands_ = takeCommandBo(4 * w.size(), &error);
        hm_perf_end(HM_PERF_COMMAND_BO, mark, 4 * w.size());
        int e = error;
        uint32_t fence = 0;
        const uint64_t faults = gpu_.faults();
        if (first->commands_ != nullptr) {
            mark = hm_perf_begin();
            memcpy(first->commands_->cpu(), w.data(), 4 * w.size());
            hm_perf_end(HM_PERF_UPLOAD, mark, 4 * w.size());
            const auto pieces = pm4::pieces(w);
            gLongestStream = std::max<uint32_t>(gLongestStream.load(), uint32_t(w.size()));
            if (pieces.size() > 1) gStreamsCut++;
            mark = hm_perf_begin();
            e = gpu_.submit(id_, *first->commands_, 0, pieces, batch.size() == 1 ? first->uses_ : uses, &fence);
            hm_perf_end(HM_PERF_GPU_SUBMIT, mark, 0);
        }
        if (e != 0) {
            const std::string why = first->commands_ == nullptr ? "no memory for the command stream: " : "the driver refused the submission: ";
            {
                std::lock_guard<std::mutex> g(lock_);
                if (first->commands_) idle_.push_back(std::move(first->commands_));
                for (const auto& part : batch) {
                    part->error_ = why + strerror(e);
                    inFlight_.push_back(part);
                    part->submissionResolved_ = true;
                }
            }
            changed_.notify_all();
            continue;
        }
        {
            std::lock_guard<std::mutex> g(lock_);
            first->counts_.merged = uint32_t(batch.size() - 1);
            if (first->profile_) {
                const uint64_t now = hm_perf_clock(CLOCK_MONOTONIC);
                if (encodeWindow_ == 0) encodeWindow_ = now;
                encodeSubmits_++;
                for (const auto& part : batch) {
                    encodeCbs_++;
                    encodeCounts_.draws += part->counts_.draws;
                    encodeCounts_.gmemPasses += part->counts_.gmemPasses;
                    encodeCounts_.sysmemPasses += part->counts_.sysmemPasses;
                    encodeCounts_.wfis += part->counts_.wfis;
                    encodeCounts_.fetchBarriers += part->counts_.fetchBarriers;
                    encodeCounts_.chained += part->counts_.chained;
                    encodeCounts_.encodeNs += part->counts_.encodeNs;
                }
                if (now - encodeWindow_ >= 2000000000ull) {
                    fprintf(stderr, "encode-v29: cb=%u submit=%u merged=%u sysmem=%u gmem=%u wfi=%u wfi_per_cb=%.2f fbBarrier=%u chain=%u draws=%u encode_us_per_draw=%.2f batched_commits=%u cb_per_drain=%.2f drain_reason=surface:%u,cpu_sync:%u,cross_queue:%u,limit:%u,idle:%u\n",
                        encodeCbs_, encodeSubmits_, encodeCbs_ - encodeSubmits_, encodeCounts_.sysmemPasses, encodeCounts_.gmemPasses,
                        encodeCounts_.wfis, double(encodeCounts_.wfis) / encodeCbs_, encodeCounts_.fetchBarriers, encodeCounts_.chained, encodeCounts_.draws,
                        encodeCounts_.draws ? double(encodeCounts_.encodeNs) / (1000.0 * encodeCounts_.draws) : 0.0,
                        encodeBatchedCommits_, encodeDrains_ ? double(encodeDrainCbs_) / encodeDrains_ : 0.0,
                        encodeDrainReasons_[kSurface], encodeDrainReasons_[kCpuSync], encodeDrainReasons_[kCrossQueue],
                        encodeDrainReasons_[kLimit], encodeDrainReasons_[kIdle]);
                    encodeDrainReasons_ = {};
                    encodeDrains_ = encodeDrainCbs_ = encodeBatchedCommits_ = 0;
                    encodeCounts_ = {}; encodeCbs_ = encodeSubmits_ = 0; encodeWindow_ = now;
                }
            }
            for (const auto& part : batch) {
                part->fence_ = fence;
                part->faultsAtCommit_ = faults;
                part->status_ = CommandBuffer::kScheduled;
                inFlight_.push_back(part);
                part->submissionResolved_ = true;
            }
        }
        changed_.notify_all();
    }
}

void CommandQueue::waiter() {
    std::unique_lock<std::mutex> g(lock_);
    for (;;) {
        changed_.wait(g, [this] { return quit_ || !inFlight_.empty(); });
        if (inFlight_.empty()) {
            return;  // quitting, and nothing left in flight
        }
        std::shared_ptr<CommandBuffer> cb = inFlight_.front();
        g.unlock();
        if (cb->error_.empty() && cb->scheduledHandler_) {
            cb->scheduledHandler_();
            cb->scheduledHandler_ = {};
        }
        if (!cb->error_.empty()) { // rejected recording/submission: retire in queue order without a GPU wait
            cb->completedAt_ = gpu_.transport().nowNs();
            cb->finish(CommandBuffer::kError);
            g.lock();
            inFlight_.pop_front();
            continue;
        }
        // A fence that passed is not yet a submission that ran. When the kernel resets a hung GPU (gpu_recover=1) it
        // gives up the submission the GPU hung on -- its fence is written as passed, so its wait ends as if it had run
        // -- and runs the ones behind it again (hakios_gpu_recover). FAULTS counts the resets; GIVEN_UP says which
        // submissions were given up. A wait the reset ended early, for one that is run again, is waited again.
        int e;
        uint64_t faults = cb->faultsAtCommit_, before;
        bool givenUp;
        do {
            before = faults;
            e = gpu_.wait(id_, cb->fence_, kPatienceNs);
            faults = gpu_.faults();
            givenUp = faults > cb->faultsAtCommit_ && gpu_.givenUp(cb->fence_);
        } while (e == ETIMEDOUT && !givenUp && faults != before);
        cb->completedAt_ = gpu_.transport().nowNs();
        if (e == 0 && givenUp) {
            cb->error_ = "given up by a reset of the GPU (it hung on this submission): not run";
            e = EIO;
        } else if (e == ETIMEDOUT) {
            cb->error_ = faults > cb->faultsAtCommit_ ? "the GPU faulted or timed out; the kernel reset it (reset " +
                                                            std::to_string(faults) + " of this run)"
                                                      : "the GPU faulted or timed out; recovery is disabled or failed";
        }
        // where this queue's last GMEM pass got to (render::encodeGmem's progress: step << 28 | pass << 16 | tile), for
        // a hang whether the kernel recovered (gpu_recover=1: "given up") or not; step 7 is a pass that finished
        if (givenUp || e == ETIMEDOUT) {
            std::shared_ptr<Buffer> trace;
            {
                std::lock_guard<std::mutex> t(lock_);
                trace = gmemTrace_;
            }
            if (trace != nullptr && trace->contents() != nullptr) {
                const uint32_t v = *static_cast<const volatile uint32_t*>(trace->contents());
                char text[96];
                snprintf(text, sizeof text, "; gmem-trace %#x (step %u, pass %u, tile %u)", v, v >> 28, (v >> 16) & 0xfffu, v & 0xffffu);
                cb->error_ += text;
            }
        } else if (e != 0) {
            cb->error_ = std::string("waiting for it failed: ") + strerror(e);
        }
        cb->finish(e == 0 ? CommandBuffer::kCompleted : CommandBuffer::kError);
        g.lock();
        inFlight_.pop_front();
        if (cb->commands_ != nullptr) {
            idle_.push_back(std::move(cb->commands_));
        }
    }
}

}  // namespace hakios::metal
