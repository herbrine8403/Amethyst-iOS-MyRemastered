// SimpleFPEWrapper - SimpleFPEWrapper/fpe/list_diagnostics.h
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#pragma once

#include "../init.h" // SFPEW_LIST_DEBUG

#include <cstddef>

#if SFPEW_LIST_DEBUG
// ---- SFPEW_LISTLOG: display-list geometry accounting -------------------
// Minecraft's terrain lives entirely in display lists, and every way this
// wrapper can lose a chunk is silent by construction: a draw whose client
// arrays cannot be snapshotted is dropped from the list rather than replayed
// from stale memory, an arena allocation that the driver refused still
// reports success, and a list that compiled to nothing simply draws nothing.
// The symptom is identical in all three cases - geometry that never appears -
// so the only way to tell them apart is to count them.
//
// SFPEW_LISTLOG=1 prints a per-frame summary plus a detailed line for the
// first few occurrences of each failure. Off by default and behind a single
// bool test, so nothing here costs anything in a normal run.
// Two bisection switches for the device. Everything the accounting can see
// is healthy - the wrapper submits every list the game asks for - so what
// remains is geometry that is submitted and does not land, and the two ways
// that can happen both involve state shared between lists.
//
// SFPEW_NO_LIST_BATCH=1 stops merging a glCallLists group into one
// multi-draw, replaying each list on its own instead. That takes the
// per-list baseVertex out of the picture.
//
// SFPEW_NO_LIST_ARENA=1 gives every captured list its own vertex buffer
// instead of a slice of one 64 MiB arena, so no list can be affected by
// another's offset or by arena reuse.
//
// Both cost performance and neither changes what is drawn, so a symptom that
// disappears under one of them names its own cause.
bool listBatchDisabled();

// SFPEW_LIST_BATCH_LOOP=1 keeps the batch path exactly as it is - one state
// commit for the whole group, same buffer, same per-list first and count -
// but issues the group as individual draws instead of one multi-draw. It
// isolates the multi-draw entry point itself from everything around it,
// which is all that still differs between a batched group and the per-list
// replay that renders correctly.
bool listBatchLoopOnly();

bool listArenaDisabled();

bool listLogEnabled();

// Emits one accounting line to logcat and to the device file.
void listLogLine(bool warn, const char* format, ...);

struct list_log_counters_t {
    // Per frame
    unsigned requested = 0;      // lists the app asked to draw this frame
    unsigned drawnLists = 0;     // lists actually replayed (loop + batched)
    unsigned calls = 0;          // lists invoked by glCallList(s)
    unsigned callsMissing = 0;   // invoked ids with no list object
    unsigned callsEmpty = 0;     // invoked lists that hold no commands
    unsigned replayDraws = 0;    // captured draws actually executed
    unsigned batchTry = 0, batchOk = 0;
    unsigned captureOk = 0, captureFail = 0, preconditionSkip = 0;
    unsigned arenaOk = 0, arenaFail = 0, dedicated = 0, staticFail = 0;
    unsigned compiled = 0, compiledEmpty = 0;
    // List lifecycle, so a frame that stops drawing can be told apart from a
    // frame whose lists were deleted or never recorded.
    unsigned gens = 0, genRange = 0, deletes = 0, deleteRange = 0, recordings = 0;
    unsigned callListsBatches = 0, callListSingles = 0;
    // Geometry volume, independent of how many lists carried it.
    unsigned long long vertsDrawn = 0, vertsCompiled = 0;
    unsigned drawsTotal = 0;
    // The ids of a frame that asks for almost nothing, to see whether it is
    // the same chunk every time.
    GLuint idSample[8] = {};
    unsigned idSampleCount = 0;
    // Whole run, for the "first N" detail lines
    unsigned detailsCapture = 0, detailsPrecondition = 0, detailsArena = 0, detailsEmpty = 0,
             detailsBatch = 0, detailsMissing = 0;
};
extern list_log_counters_t g_listLog;
constexpr unsigned kListLogDetailLimit = 12;

// Counts an arena rejection and names the reason for the first few.
bool listLogArenaFail(const char* reason, size_t size);

// Counts a tally step only in a build that has the accounting.
#define SFPEW_LISTLOG_TALLY(statement)                                                             \
    do {                                                                                           \
        statement;                                                                                 \
    } while (0)
#else
// Without the accounting these fold away entirely; an arena rejection is
// still a plain false, and the bisection switches read as permanently off.
inline bool listLogEnabled() { return false; }
inline bool listBatchDisabled() { return false; }
inline bool listArenaDisabled() { return false; }
inline bool listBatchLoopOnly() { return false; }
inline bool listLogArenaFail(const char*, size_t) { return false; }
#define SFPEW_LISTLOG_TALLY(statement)                                                             \
    do {                                                                                           \
    } while (0)
#endif
