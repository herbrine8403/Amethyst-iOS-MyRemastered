// SimpleFPEWrapper - SimpleFPEWrapper/fpe/list_diagnostics.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#include "list_diagnostics.h"

#include "../log.h"
#include "../version.h" // SFPEW_GIT_COMMIT, for the LISTLOG accounting header below
#include "list.h"

#include <cerrno>
#include <cstdarg>
#include <cstdio>
#include <cstring>

#if SFPEW_LIST_DEBUG
bool listBatchDisabled() {
    static const bool disabled = [] {
        const char* v = getenv("SFPEW_NO_LIST_BATCH");
        return v != nullptr && v[0] != '\0' && !(v[0] == '0' && v[1] == '\0');
    }();
    return disabled;
}

bool listBatchLoopOnly() {
    static const bool loop = [] {
        const char* v = getenv("SFPEW_LIST_BATCH_LOOP");
        return v != nullptr && v[0] != '\0' && !(v[0] == '0' && v[1] == '\0');
    }();
    return loop;
}

bool listArenaDisabled() {
    static const bool disabled = [] {
        const char* v = getenv("SFPEW_NO_LIST_ARENA");
        return v != nullptr && v[0] != '\0' && !(v[0] == '0' && v[1] == '\0');
    }();
    return disabled;
}

bool listLogEnabled() {
    static const bool enabled = [] {
        const char* v = getenv("SFPEW_LISTLOG");
        return v != nullptr && v[0] != '\0' && !(v[0] == '0' && v[1] == '\0');
    }();
    return enabled;
}

namespace {

// The same lines also go to a file on the device, because a logcat buffer
// wraps long before a session is over and this accounting is only useful as
// a whole run. Truncated at open, so the file always holds the latest run.
FILE* listLogFile() {
    static FILE* file = []() -> FILE* {
        if (!listLogEnabled()) return nullptr;
        const char* path = getenv("SFPEW_LISTLOG_FILE");
        if (path == nullptr || *path == '\0') path = "/sdcard/sfpew-listlog.txt";
        FILE* opened = fopen(path, "w");
        if (opened == nullptr) {
            SFPEW_LOGW("LISTLOG cannot write %s (%s); logcat only", path, strerror(errno));
            return nullptr;
        }
        setvbuf(opened, nullptr, _IOLBF, 0);
        fprintf(opened, "SFPEW display-list accounting, commit %s, built %s%s%s\n",
                SFPEW_GIT_COMMIT, __DATE__ " " __TIME__,
                listBatchDisabled() ? " [NO_LIST_BATCH]"
                                    : (listBatchLoopOnly() ? " [LIST_BATCH_LOOP]" : ""),
                listArenaDisabled() ? " [NO_LIST_ARENA]" : "");
        fflush(opened);
        SFPEW_LOGI("LISTLOG writing to %s", path);
        return opened;
    }();
    return file;
}

} // namespace

// Emits one accounting line to logcat and to the device file.
void listLogLine(bool warn, const char* format, ...) {
    char line[512];
    va_list args;
    va_start(args, format);
    vsnprintf(line, sizeof line, format, args);
    va_end(args);
    if (warn) {
        SFPEW_LOGW("%s", line);
    } else {
        SFPEW_LOGI("%s", line);
    }
    FILE* file = listLogFile();
    if (file != nullptr) {
        fputs(line, file);
        fputc('\n', file);
        fflush(file);
    }
}

list_log_counters_t g_listLog;

// Counts an arena rejection and names the reason for the first few.
bool listLogArenaFail(const char* reason, size_t size) {
    ++g_listLog.arenaFail;
    if (listLogEnabled() && g_listLog.detailsArena++ < kListLogDetailLimit) {
        listLogLine(true, "LISTLOG arena allocate REJECTED (%s) size=%zu", reason, size);
    }
    return false;
}

// One line per frame with everything that could have lost geometry, so a
// device log shows at a glance whether chunks are being dropped at capture,
// at replay, or never called at all. Called from the swap wrappers.
void sfpewListLogFrame() {
    if (!listLogEnabled()) return;
    static unsigned frame = 0;
    auto& c = g_listLog;
    // Nothing happened since the last summary; the caller is one of several
    // frame boundaries (swap, clear, periodic) and only the first should print.
    if (c.requested == 0 && c.compiled == 0 && c.replayDraws == 0) return;
    unsigned probeTotal = 0, probeFilled = 0;
    DisplayListManager::inventory(&probeTotal, &probeFilled);
    const bool interesting = c.requested != c.drawnLists || c.callsMissing || c.captureFail ||
                             c.preconditionSkip || c.staticFail ||
                             (probeFilled >= 50 && c.requested * 8 < probeFilled);
    // Every frame while something is wrong, otherwise one in sixty.
    if (interesting || (frame % 60) == 0) {
        unsigned heldTotal = 0, heldFilled = 0;
        DisplayListManager::inventory(&heldTotal, &heldFilled);
        // The wrapper is holding plenty of chunk geometry and the game is
        // asking for almost none of it: that is the reported symptom, and
        // labeling it here means the log identifies its own bad frames.
        const bool symptom = heldFilled >= 50 && c.requested * 8 < heldFilled;
        listLogLine(c.requested != c.drawnLists || symptom,
                   "LISTLOG frame=%u lists=%u/%u%s%s held=%u/%u verts=%llu draws=%u "
                   "callLists=%u+%u calls=%u(missing=%u empty=%u) batch=%u/%u replayDraws=%u",
                   frame, c.drawnLists, c.requested,
                   c.requested != c.drawnLists ? " LOST!" : "", symptom ? " SYMPTOM" : "",
                   heldFilled, heldTotal, c.vertsDrawn, c.drawsTotal, c.callListsBatches,
                   c.callListSingles, c.calls, c.callsMissing, c.callsEmpty, c.batchOk,
                   c.batchTry, c.replayDraws);
        listLogLine(false,
                   "LISTLOG frame=%u   lifecycle gen=%u(+%u ids) del=%u(-%u ids) record=%u "
                   "compiled=%u(empty=%u) vertsCompiled=%llu capture=%u/%u skip=%u "
                   "arena=%u(fail=%u) dedicated=%u staticFail=%u",
                   frame, c.gens, c.genRange, c.deletes, c.deleteRange, c.recordings, c.compiled,
                   c.compiledEmpty, c.vertsCompiled, c.captureOk, c.captureOk + c.captureFail,
                   c.preconditionSkip, c.arenaOk, c.arenaFail, c.dedicated, c.staticFail);
        if (symptom && c.idSampleCount != 0) {
            char ids[128] = "";
            size_t at = 0;
            for (unsigned i = 0; i < c.idSampleCount && at + 12 < sizeof ids; ++i)
                at += (size_t)snprintf(ids + at, sizeof ids - at, "%u ", c.idSample[i]);
            listLogLine(true, "LISTLOG frame=%u   asked for lists: %s", frame, ids);
        }
    }
    ++frame;
    const unsigned dc = c.detailsCapture, dp = c.detailsPrecondition, da = c.detailsArena,
                   de = c.detailsEmpty, db = c.detailsBatch, dm = c.detailsMissing;
    c = {};
    c.detailsCapture = dc; c.detailsPrecondition = dp; c.detailsArena = da;
    c.detailsEmpty = de; c.detailsBatch = db; c.detailsMissing = dm;
}

// Called by list.cpp for the compile/call side of the same accounting.
void sfpewListLogCompiled(GLuint list, size_t commands) {
    ++g_listLog.compiled;
    if (commands != 0) return;
    ++g_listLog.compiledEmpty;
    if (listLogEnabled() && g_listLog.detailsEmpty++ < kListLogDetailLimit) {
        listLogLine(true, "LISTLOG list %u compiled EMPTY - anything it should draw is now lost", list);
    }
}

void sfpewListLogRequested(unsigned lists) {
    g_listLog.requested += lists;
    ++g_listLog.callListsBatches;
}

// The ids themselves, kept only while a frame asks for very few of them.
void sfpewListLogRequestedIds(const GLuint* ids, unsigned count) {
    sfpewListLogRequested(count);
    if (ids == nullptr || count > 8) return;
    for (unsigned i = 0; i < count && g_listLog.idSampleCount < 8; ++i)
        g_listLog.idSample[g_listLog.idSampleCount++] = ids[i];
}

void sfpewListLogGenerated(unsigned range) {
    ++g_listLog.gens;
    g_listLog.genRange += range;
}

void sfpewListLogDeleted(unsigned range) {
    ++g_listLog.deletes;
    g_listLog.deleteRange += range;
}

void sfpewListLogRecording(GLuint) { ++g_listLog.recordings; }

void sfpewListLogDrawIssued() { ++g_listLog.drawsTotal; }

void sfpewListLogDrewOne() { ++g_listLog.drawnLists; }

void sfpewListLogSingleCall() { ++g_listLog.callListSingles; }

// The frustum matrices, once every few seconds and again whenever they stop
// looking like a camera - a zero row or a degenerate projection culls the
// whole world while every other counter here stays perfectly healthy.
void sfpewListLogMatrixQuery(const char* which, unsigned slot, size_t stackDepth,
                             const GLfloat* matrix) {
    if (!listLogEnabled()) return;
    // One counter per matrix: a shared one prints whichever the application
    // happens to ask for first and hides the other completely.
    static unsigned queries[4] = {0, 0, 0, 0};
    bool finite = true;
    float magnitude = 0.0f;
    for (int i = 0; i < 16; ++i) {
        if (!(matrix[i] == matrix[i]) || matrix[i] > 1e18f || matrix[i] < -1e18f) finite = false;
        magnitude += matrix[i] < 0 ? -matrix[i] : matrix[i];
    }
    // An identity modelview is a camera that never moved: the frustum built
    // from it sits at the world origin and culls everything the player can
    // actually see.
    const bool identity = matrix[0] == 1.0f && matrix[5] == 1.0f && matrix[10] == 1.0f &&
                          matrix[15] == 1.0f && matrix[12] == 0.0f && matrix[13] == 0.0f &&
                          matrix[14] == 0.0f && matrix[1] == 0.0f && matrix[4] == 0.0f;
    const bool suspicious = !finite || magnitude < 1e-6f || identity;
    unsigned& seen = queries[slot & 3u];
    if (!suspicious && (seen++ % 300) != 0) return;
    listLogLine(suspicious,
                "LISTLOG %s%s depth=%zu [%.3f %.3f %.3f %.3f | %.3f %.3f %.3f %.3f | "
                "%.3f %.3f %.3f %.3f | %.3f %.3f %.3f %.3f]",
                which, suspicious ? (identity ? " IDENTITY" : " SUSPICIOUS") : "", stackDepth,
                matrix[0], matrix[1], matrix[2], matrix[3], matrix[4], matrix[5], matrix[6],
                matrix[7], matrix[8], matrix[9], matrix[10], matrix[11], matrix[12], matrix[13],
                matrix[14], matrix[15]);
}

void sfpewListLogCalled(GLuint list, int found, size_t commands) {
    ++g_listLog.calls;
    ++g_listLog.drawnLists;
    if (!found) {
        --g_listLog.drawnLists;
        ++g_listLog.callsMissing;
        if (listLogEnabled() && g_listLog.detailsMissing++ < kListLogDetailLimit)
            listLogLine(true, "LISTLOG glCallList(%u): no such list", list);
        return;
    }
    if (commands == 0) ++g_listLog.callsEmpty;
}
#endif
