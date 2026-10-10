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

#include "swiftbridge/dtb.h"

#include "common/darktable.h"
#include "mcp/dt_bridge.h"

#include <glib.h>
#include <json-glib/json-glib.h>
#include <string.h>

static GMutex _lock;
static gboolean _up = FALSE;
// dt_init keeps pointers into argv, so the vector lives for the whole process
static char **_argv = NULL;

static void _fail(char **err, const char *msg)
{
  if(err) *err = g_strdup(msg);
}

int dtb_init(const char *datadir, const char *moduledir, const char *configdir,
             const char *cachedir, const char *library, char **err)
{
  g_mutex_lock(&_lock);
  if(_up)
  {
    g_mutex_unlock(&_lock);
    return 0;
  }

  GPtrArray *a = g_ptr_array_new();
  g_ptr_array_add(a, g_strdup("darktable-swift"));
  g_ptr_array_add(a, g_strdup("--library"));
  g_ptr_array_add(a, g_strdup(library && *library ? library : ":memory:"));
  if(configdir && *configdir)
  {
    g_ptr_array_add(a, g_strdup("--configdir"));
    g_ptr_array_add(a, g_strdup(configdir));
  }
  if(cachedir && *cachedir)
  {
    g_ptr_array_add(a, g_strdup("--cachedir"));
    g_ptr_array_add(a, g_strdup(cachedir));
  }
  if(datadir && *datadir)
  {
    g_ptr_array_add(a, g_strdup("--datadir"));
    g_ptr_array_add(a, g_strdup(datadir));

    // <prefix>/share/darktable -> <prefix>/share/locale
    gchar *share = g_path_get_dirname(datadir);
    gchar *locale = g_build_filename(share, "locale", NULL);
    if(g_file_test(locale, G_FILE_TEST_IS_DIR))
    {
      g_ptr_array_add(a, g_strdup("--localedir"));
      g_ptr_array_add(a, g_strdup(locale));
    }
    g_free(locale);
    g_free(share);
  }
  if(moduledir && *moduledir)
  {
    g_ptr_array_add(a, g_strdup("--moduledir"));
    g_ptr_array_add(a, g_strdup(moduledir));
  }
  // a front end that only looks must never drop sidecar files next to raws
  g_ptr_array_add(a, g_strdup("--conf"));
  g_ptr_array_add(a, g_strdup("write_sidecar_files=never"));
  g_ptr_array_add(a, NULL);

  const int argc = (int)a->len - 1;
  _argv = (char **)g_ptr_array_free(a, FALSE);

  if(dt_init(argc, _argv, FALSE, TRUE, NULL))
  {
    _fail(err, "dt_init failed");
    g_mutex_unlock(&_lock);
    return 1;
  }
  _up = TRUE;
  g_mutex_unlock(&_lock);
  return 0;
}

void dtb_shutdown(void)
{
  g_mutex_lock(&_lock);
  if(_up)
  {
    dt_cleanup();
    _up = FALSE;
  }
  g_mutex_unlock(&_lock);
}

int dtb_render(const char *path, int imgid, int max_w, int max_h,
               const char *stack_json, dtb_frame *out, char **err)
{
  if(!out)
  {
    _fail(err, "no output frame");
    return 1;
  }
  memset(out, 0, sizeof(*out));

  g_mutex_lock(&_lock);
  if(!_up)
  {
    g_mutex_unlock(&_lock);
    _fail(err, "engine not started");
    return 1;
  }

  JsonParser *parser = NULL;
  JsonArray *stack = NULL;
  if(stack_json && *stack_json)
  {
    parser = json_parser_new();
    GError *ge = NULL;
    if(!json_parser_load_from_data(parser, stack_json, -1, &ge))
    {
      _fail(err, ge ? ge->message : "stack is not valid JSON");
      if(ge) g_error_free(ge);
      g_object_unref(parser);
      g_mutex_unlock(&_lock);
      return 1;
    }
    JsonNode *root = json_parser_get_root(parser);
    if(root && JSON_NODE_HOLDS_ARRAY(root)) stack = json_node_get_array(root);
  }

  uint8_t *buf = NULL;
  int w = 0, h = 0, stride = 0;
  char *gerr = NULL;
  const gboolean ok = dt_bridge_render_rgb24(path, imgid, max_w, max_h, stack, FALSE, -1,
                                             &buf, &w, &h, &stride, &gerr);
  if(parser) g_object_unref(parser);
  g_mutex_unlock(&_lock);

  if(!ok)
  {
    if(err) *err = gerr ? gerr : g_strdup("render failed");
    else g_free(gerr);
    return 1;
  }
  g_free(gerr);
  out->pixels = buf;
  out->width = w;
  out->height = h;
  out->stride = stride;
  return 0;
}

dtb_session *dtb_session_open(const char *path, int imgid, int max_w, int max_h, char **err)
{
  g_mutex_lock(&_lock);
  if(!_up)
  {
    g_mutex_unlock(&_lock);
    _fail(err, "engine not started");
    return NULL;
  }
  char *gerr = NULL;
  dt_bridge_session_t *s = dt_bridge_session_open(path, imgid, max_w, max_h, &gerr);
  g_mutex_unlock(&_lock);
  if(!s)
  {
    if(err) *err = gerr ? gerr : g_strdup("could not open the image");
    else g_free(gerr);
  }
  else
    g_free(gerr);
  return (dtb_session *)s;
}

int dtb_session_render(dtb_session *session, const char *stack_json, dtb_frame *out, char **err)
{
  if(!out || !session)
  {
    _fail(err, "no session or output frame");
    return 1;
  }
  memset(out, 0, sizeof(*out));

  JsonParser *parser = NULL;
  JsonArray *stack = NULL;
  if(stack_json && *stack_json)
  {
    parser = json_parser_new();
    GError *ge = NULL;
    if(!json_parser_load_from_data(parser, stack_json, -1, &ge))
    {
      _fail(err, ge ? ge->message : "stack is not valid JSON");
      if(ge) g_error_free(ge);
      g_object_unref(parser);
      return 1;
    }
    JsonNode *root = json_parser_get_root(parser);
    if(root && JSON_NODE_HOLDS_ARRAY(root)) stack = json_node_get_array(root);
  }

  g_mutex_lock(&_lock);
  uint8_t *buf = NULL;
  int w = 0, h = 0, stride = 0;
  char *gerr = NULL;
  const gboolean ok = _up
    && dt_bridge_session_render((dt_bridge_session_t *)session, stack, &buf, &w, &h, &stride, &gerr);
  g_mutex_unlock(&_lock);
  if(parser) g_object_unref(parser);

  if(!ok)
  {
    if(err) *err = gerr ? gerr : g_strdup("render failed");
    else g_free(gerr);
    return 1;
  }
  g_free(gerr);
  out->pixels = buf;
  out->width = w;
  out->height = h;
  out->stride = stride;
  return 0;
}

int dtb_session_render_region(dtb_session *session, const char *stack_json, double scale,
                              int x, int y, int w, int h, dtb_frame *out, char **err)
{
  if(!out || !session)
  {
    _fail(err, "no session or output frame");
    return 1;
  }
  memset(out, 0, sizeof(*out));

  JsonParser *parser = NULL;
  JsonArray *stack = NULL;
  if(stack_json && *stack_json)
  {
    parser = json_parser_new();
    GError *ge = NULL;
    if(!json_parser_load_from_data(parser, stack_json, -1, &ge))
    {
      _fail(err, ge ? ge->message : "stack is not valid JSON");
      if(ge) g_error_free(ge);
      g_object_unref(parser);
      return 1;
    }
    JsonNode *root = json_parser_get_root(parser);
    if(root && JSON_NODE_HOLDS_ARRAY(root)) stack = json_node_get_array(root);
  }

  g_mutex_lock(&_lock);
  uint8_t *buf = NULL;
  int stride = 0;
  char *gerr = NULL;
  const gboolean ok = _up
    && dt_bridge_session_render_region((dt_bridge_session_t *)session, stack, scale,
                                       x, y, w, h, &buf, &stride, &gerr);
  g_mutex_unlock(&_lock);
  if(parser) g_object_unref(parser);

  if(!ok)
  {
    if(err) *err = gerr ? gerr : g_strdup("render failed");
    else g_free(gerr);
    return 1;
  }
  g_free(gerr);
  out->pixels = buf;
  out->width = w;
  out->height = h;
  out->stride = stride;
  return 0;
}

void dtb_session_info(dtb_session *session, int *processed_w, int *processed_h,
                      int *work_w, int *work_h)
{
  if(!session) return;
  g_mutex_lock(&_lock);
  if(_up) dt_bridge_session_info((dt_bridge_session_t *)session, processed_w, processed_h,
                                 work_w, work_h);
  g_mutex_unlock(&_lock);
}

char *dtb_session_modules_json(dtb_session *session, char **err)
{
  if(!session)
  {
    _fail(err, "no session");
    return NULL;
  }
  g_mutex_lock(&_lock);
  char *gerr = NULL;
  char *s = _up ? dt_bridge_session_modules_json((dt_bridge_session_t *)session, &gerr) : NULL;
  g_mutex_unlock(&_lock);
  if(!s)
  {
    if(err) *err = gerr ? gerr : g_strdup("could not list modules");
    else g_free(gerr);
  }
  else
    g_free(gerr);
  return s;
}

void dtb_session_close(dtb_session *session)
{
  if(!session) return;
  g_mutex_lock(&_lock);
  if(_up) dt_bridge_session_close((dt_bridge_session_t *)session);
  g_mutex_unlock(&_lock);
}

void dtb_frame_free(dtb_frame *frame)
{
  if(!frame) return;
  g_free(frame->pixels);
  memset(frame, 0, sizeof(*frame));
}

char *dtb_list_modules_json(void)
{
  g_mutex_lock(&_lock);
  char *s = _up ? dt_bridge_list_modules_json() : NULL;
  g_mutex_unlock(&_lock);
  return s;
}

char *dtb_module_schema_json(const char *operation, char **err)
{
  g_mutex_lock(&_lock);
  char *s = NULL;
  if(_up) s = dt_bridge_module_schema_json(operation, err);
  else _fail(err, "engine not started");
  g_mutex_unlock(&_lock);
  return s;
}

void dtb_string_free(char *s)
{
  g_free(s);
}
