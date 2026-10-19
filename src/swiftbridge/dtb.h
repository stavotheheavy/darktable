/*
    This file is part of darktable,
    Copyright (C) 2026 darktable developers.

    darktable is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    darktable is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with darktable.  If not, see <http://www.gnu.org/licenses/>.
*/

// a small plain-C surface over libdarktable's headless engine for a native
// (Swift) front end. no GLib or darktable types appear here, so a Swift module
// map can import this header without pulling in the GTK stack's headers.
//
// every call is serialized internally, but the engine is not designed for
// arbitrary threads: drive it from one dedicated thread.
//
// strings returned by this API (including *err) are owned by the caller and
// must be released with dtb_string_free()

#ifndef DTB_H
#define DTB_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct dtb_frame
{
  uint8_t *pixels; // 8-bit B,G,R,x (little-endian cairo RGB24); free with dtb_frame_free
  int width;
  int height;
  int stride; // bytes per row
} dtb_frame;

/** start the engine without a GUI. `library` NULL means an in-memory catalog.
    `datadir` is <prefix>/share/darktable, `moduledir` is <prefix>/lib/darktable.
    returns 0 on success */
int dtb_init(const char *datadir, const char *moduledir, const char *configdir,
             const char *cachedir, const char *library, char **err);

void dtb_shutdown(void);

/** render `path` (not in the catalog: imported as a scratch image and dropped
    again) or catalog image `imgid` (path NULL) into `out`, fitted inside
    max_w x max_h (0 = unconstrained). `stack_json` is NULL or a JSON array of
    {"operation": "exposure", "params": {"exposure": 0.5}, "enabled": true}.
    returns 0 on success */
int dtb_render(const char *path, int imgid, int max_w, int max_h,
               const char *stack_json, dtb_frame *out, char **err);

/** a persistent render session: one image kept open at one working size, with its
    decoded raw and per-module cache alive between renders, so an edit only
    re-runs from the changed module onward */
typedef struct dtb_session dtb_session;

/** open `path` (or catalog image `imgid`, path NULL). frames fit max_w x max_h
    (0 = unbounded). returns NULL with *err set on failure */
dtb_session *dtb_session_open(const char *path, int imgid, int max_w, int max_h, char **err);

/** returned by the session renders when dtb_session_cancel stopped them */
#define DTB_CANCELED 2

/** render with exactly `stack_json` applied on top of the imported state (the same
    JSON array dtb_render takes; NULL or "[]" is the unedited image).
    returns 0 on success, DTB_CANCELED when canceled */
int dtb_session_render(dtb_session *session, const char *stack_json,
                       dtb_frame *out, char **err);

/** one region of the image at an explicit scale (1.0 = full resolution output),
    x,y,w,h in that scaled image's pixels: what a zoomed or panned view needs */
int dtb_session_render_region(dtb_session *session, const char *stack_json, double scale,
                              int x, int y, int w, int h, dtb_frame *out, char **err);

/** stop the render `session` is running, if any, so a superseded edit is not
    finished. the one call that may come from another thread while a render
    holds the engine: it takes no lock and returns at once. the caller must
    keep `session` from being closed during the call */
void dtb_session_cancel(dtb_session *session);

/** full-resolution output size, and the size of dtb_session_render frames */
void dtb_session_info(dtb_session *session, int *processed_w, int *processed_h,
                      int *work_w, int *work_h);

/** JSON array of the session's modules in pipeline order, each with its current
    scalar parameters and blend parameters (the imported state) */
char *dtb_session_modules_json(dtb_session *session, char **err);

void dtb_session_close(dtb_session *session);

void dtb_frame_free(dtb_frame *frame);

/** JSON array of [{ operation, version, have_introspection, doc_url }] */
char *dtb_list_modules_json(void);

/** JSON description of one module's parameter fields, or NULL with *err set */
char *dtb_module_schema_json(const char *operation, char **err);

void dtb_string_free(char *s);

#ifdef __cplusplus
}
#endif

#endif
