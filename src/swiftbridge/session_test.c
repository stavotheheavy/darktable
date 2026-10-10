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

// dtb-session-test <image> [--max 1400]
//
// times the persistent render session against the one-shot render and checks
// that cached frames are the right frames. prints one line per step.

#include "swiftbridge/dtb.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

static double _now_ms(void)
{
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static double _rss_mb(void)
{
  struct rusage ru;
  getrusage(RUSAGE_SELF, &ru);
#ifdef __APPLE__
  return ru.ru_maxrss / (1024.0 * 1024.0); // bytes
#else
  return ru.ru_maxrss / 1024.0; // kilobytes
#endif
}

// mean absolute difference over the colour bytes, and the largest single difference
static void _diff(const dtb_frame *a, const dtb_frame *b, double *mean, int *max)
{
  *mean = -1;
  *max = -1;
  if(a->width != b->width || a->height != b->height) return;
  double sum = 0;
  int mx = 0;
  size_t n = 0;
  for(int y = 0; y < a->height; y++)
    for(int x = 0; x < a->width; x++)
      for(int c = 0; c < 3; c++)
      {
        const int d = abs((int)a->pixels[y * a->stride + x * 4 + c]
                          - (int)b->pixels[y * b->stride + x * 4 + c]);
        sum += d;
        if(d > mx) mx = d;
        n++;
      }
  *mean = n ? sum / n : 0;
  *max = mx;
}

static double _luma(const dtb_frame *f)
{
  double sum = 0;
  size_t n = 0;
  for(int y = 0; y < f->height; y += 4)
    for(int x = 0; x < f->width; x += 4)
    {
      const uint8_t *p = f->pixels + y * f->stride + x * 4;
      sum += 0.0722 * p[0] + 0.7152 * p[1] + 0.2126 * p[2];
      n++;
    }
  return n ? sum / n : 0;
}

static int _render(dtb_session *s, const char *stack, dtb_frame *out, const char *label,
                   double *ms_out)
{
  char *err = NULL;
  const double t0 = _now_ms();
  const int rc = dtb_session_render(s, stack, out, &err);
  const double ms = _now_ms() - t0;
  if(ms_out) *ms_out = ms;
  if(rc)
  {
    printf("%-34s FAILED: %s\n", label, err ? err : "?");
    dtb_string_free(err);
    return 1;
  }
  printf("%-34s %7.0f ms   %dx%d  luma %.1f\n", label, ms, out->width, out->height, _luma(out));
  return 0;
}

int main(int argc, char **argv)
{
  const char *path = NULL;
  int max = 1400;
  for(int i = 1; i < argc; i++)
  {
    if(!strcmp(argv[i], "--max") && i + 1 < argc) max = atoi(argv[++i]);
    else path = argv[i];
  }
  if(!path)
  {
    fprintf(stderr, "usage: dtb-session-test <image> [--max 1400]\n");
    return 2;
  }

  const char *prefix_env = getenv("DT_PREFIX");
  const char *home = getenv("HOME");
  char prefix[1024], datadir[1100], moduledir[1100], configdir[1100], cachedir[1100];
  snprintf(prefix, sizeof(prefix), "%s", prefix_env ? prefix_env : "/Users/Chief/darktable/build/install");
  snprintf(datadir, sizeof(datadir), "%s/share/darktable", prefix);
  snprintf(moduledir, sizeof(moduledir), "%s/lib/darktable", prefix);
  snprintf(configdir, sizeof(configdir), "%s/.config/darktable-fork", home ? home : "");
  snprintf(cachedir, sizeof(cachedir), "%s/.cache/darktable-fork", home ? home : "");

  char *err = NULL;
  double t0 = _now_ms();
  if(dtb_init(datadir, moduledir, configdir, cachedir, NULL, &err))
  {
    fprintf(stderr, "init failed: %s\n", err ? err : "?");
    return 1;
  }
  printf("%-34s %7.0f ms\n", "engine start", _now_ms() - t0);

  const char *exp_up = "[{\"operation\":\"exposure\",\"params\":{\"exposure\":1.0}}]";
  printf("%-34s %7.0f MB\n", "rss after engine start", _rss_mb());

  dtb_frame one = { 0 };
  t0 = _now_ms();
  if(dtb_render(path, 0, max, max, exp_up, &one, &err))
  {
    printf("one-shot render failed: %s\n", err ? err : "?");
    dtb_string_free(err);
    err = NULL;
  }
  else
    printf("%-34s %7.0f ms   %dx%d  luma %.1f\n", "one-shot exposure +1.0 (today)", _now_ms() - t0,
           one.width, one.height, _luma(&one));
  printf("%-34s %7.0f MB\n", "rss after one-shot", _rss_mb());

  t0 = _now_ms();
  dtb_session *s = dtb_session_open(path, 0, max, max, &err);
  if(!s)
  {
    fprintf(stderr, "session open failed: %s\n", err ? err : "?");
    return 1;
  }
  printf("%-34s %7.0f ms\n", "session open", _now_ms() - t0);

  const char *exp_up2 = "[{\"operation\":\"exposure\",\"params\":{\"exposure\":1.5}}]";
  const char *shadows = "[{\"operation\":\"exposure\",\"params\":{\"exposure\":1.0}},"
                        "{\"operation\":\"shadhi\",\"params\":{\"shadows\":60,\"highlights\":0,\"whitepoint\":0}}]";
  const char *sharpen = "[{\"operation\":\"exposure\",\"params\":{\"exposure\":1.0}},"
                        "{\"operation\":\"shadhi\",\"params\":{\"shadows\":60,\"highlights\":0,\"whitepoint\":0}},"
                        "{\"operation\":\"sharpen\",\"params\":{\"amount\":1.0,\"radius\":2.0}}]";
  const char *sharpen2 = "[{\"operation\":\"exposure\",\"params\":{\"exposure\":1.0}},"
                         "{\"operation\":\"shadhi\",\"params\":{\"shadows\":60,\"highlights\":0,\"whitepoint\":0}},"
                         "{\"operation\":\"sharpen\",\"params\":{\"amount\":1.6,\"radius\":2.0}}]";

  dtb_frame base = { 0 }, again = { 0 }, f = { 0 }, restored = { 0 };
  double ms, ms_exp = 0, ms_exp2 = 0, ms_sh = 0, ms_sharp = 0, ms_sharp2 = 0;

  if(_render(s, NULL, &base, "first frame (unedited)", &ms)) return 1;
  if(_render(s, NULL, &again, "same request again", &ms)) return 1;
  if(_render(s, exp_up, &f, "exposure +1.0 (early module)", &ms_exp)) return 1;
  dtb_frame_free(&f);
  if(_render(s, exp_up2, &f, "exposure +1.5 (early module)", &ms_exp2)) return 1;
  dtb_frame_free(&f);
  if(_render(s, exp_up, &f, "exposure +1.0 again", &ms)) return 1;
  dtb_frame session_exp = f;   // keep for the one-shot comparison
  if(_render(s, shadows, &f, "+ shadows 60 (mid module)", &ms_sh)) return 1;
  dtb_frame_free(&f);
  if(_render(s, sharpen, &f, "+ sharpen 1.0 (late module)", &ms_sharp)) return 1;
  dtb_frame_free(&f);
  if(_render(s, sharpen2, &f, "+ sharpen 1.6 (late module)", &ms_sharp2)) return 1;
  dtb_frame_free(&f);
  if(_render(s, NULL, &restored, "back to unedited", &ms)) return 1;

  double mean;
  int mx;
  _diff(&base, &restored, &mean, &mx);
  printf("\nstale-frame check: unedited -> edits -> unedited: mean diff %.4f, max %d  (%s)\n",
         mean, mx, mean == 0 ? "identical" : "DIFFERS");
  _diff(&base, &again, &mean, &mx);
  printf("repeat-request check: mean diff %.4f, max %d\n", mean, mx);

  if(one.pixels)
  {
    _diff(&session_exp, &one, &mean, &mx);
    printf("session vs one-shot, exposure +1.0: mean diff %.4f, max %d\n", mean, mx);
  }

  // ---- module list: the inspector is built from this
  {
    char *mj = dtb_session_modules_json(s, &err);
    if(!mj)
    {
      printf("modules json FAILED: %s\n", err ? err : "?");
      dtb_string_free(err);
      err = NULL;
    }
    else
    {
      int count = 0;
      for(const char *q = mj; (q = strstr(q, "\"operation\"")); q++) count++;
      printf("\nmodules: %d listed, %zu bytes of JSON\n", count, strlen(mj));
      const char *ex = strstr(mj, "\"operation\":\"exposure\"");
      if(ex)
      {
        const char *end = strstr(ex, "\"blend\"");
        const int len = end ? (int)(end - ex) : 260;
        printf("exposure entry: %.*s...\n", len > 360 ? 360 : len, ex);
      }
      const char *bl = ex ? strstr(ex, "\"blend\"") : NULL;
      if(bl) printf("exposure blend: %.150s...\n", bl);
      dtb_string_free(mj);
    }
  }

  // ---- blend: 50% opacity of +1 EV must land between unedited and +1 EV
  {
    const char *half = "[{\"operation\":\"exposure\",\"params\":{\"exposure\":1.0},"
                       "\"blend\":{\"mask_mode\":\"uniformly\",\"opacity\":50}}]";
    dtb_frame hf = { 0 };
    if(!_render(s, half, &hf, "exposure +1.0 at 50% opacity", &ms))
    {
      const double lb = _luma(&base), lh = _luma(&hf);
      printf("blend check: unedited %.1f < half %.1f < full 141.3 : %s\n", lb, lh,
             (lh > lb + 2 && lh < 140) ? "blend applied" : "NO BLEND EFFECT");
      dtb_frame_free(&hf);
    }
  }

  // ---- region render at 100%: what a zoomed view asks for
  {
    int pw = 0, ph = 0, ww = 0, wh = 0;
    dtb_session_info(s, &pw, &ph, &ww, &wh);
    printf("\nsession info: output %dx%d, working %dx%d\n", pw, ph, ww, wh);
    dtb_frame rf = { 0 };
    const int rw = 600, rh = 400;
    t0 = _now_ms();
    if(dtb_session_render_region(s, NULL, 1.0, pw / 2 - rw / 2, ph / 2 - rh / 2, rw, rh, &rf, &err))
    {
      printf("region render FAILED: %s\n", err ? err : "?");
      dtb_string_free(err);
      err = NULL;
    }
    else
    {
      printf("region 100%% (%dx%d at centre)      %7.0f ms   luma %.1f\n", rf.width, rf.height,
             _now_ms() - t0, _luma(&rf));
      dtb_frame_free(&rf);
    }
    // the same region again: the zoomed view's repaint while panning is a cache hit
    t0 = _now_ms();
    if(!dtb_session_render_region(s, NULL, 1.0, pw / 2 - rw / 2 + 40, ph / 2 - rh / 2, rw, rh, &rf, &err))
    {
      printf("region 100%% panned 40 px          %7.0f ms\n", _now_ms() - t0);
      dtb_frame_free(&rf);
    }
  }

  printf("\nsummary (ms): early edit %.0f / %.0f, mid %.0f, late %.0f / %.0f   peak RSS %.0f MB\n",
         ms_exp, ms_exp2, ms_sh, ms_sharp, ms_sharp2, _rss_mb());

  dtb_frame_free(&base);
  dtb_frame_free(&again);
  dtb_frame_free(&session_exp);
  dtb_frame_free(&restored);
  dtb_frame_free(&one);
  dtb_session_close(s);
  dtb_shutdown();
  return 0;
}
