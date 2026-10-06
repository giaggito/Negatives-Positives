#include "dr_jpeg.h"
#include <turbojpeg.h>
#include <string.h>

int dr_jpeg_encode(const unsigned char *rgb, int width, int height, int quality, int chroma444, int dpi,
                   const unsigned char *icc, size_t iccSize, unsigned char **out, size_t *outSize,
                   char *err, int errLen) {
    tjhandle h = tj3Init(TJINIT_COMPRESS);
    if (!h) { strncpy(err, "tj3Init failed", errLen); return -1; }
    int rc = 0;
    if (tj3Set(h, TJPARAM_QUALITY, quality) || tj3Set(h, TJPARAM_SUBSAMP, chroma444 ? TJSAMP_444 : TJSAMP_420) ||
        tj3Set(h, TJPARAM_OPTIMIZE, 1) || tj3Set(h, TJPARAM_PROGRESSIVE, 0)) rc = -1;
    if (!rc && dpi > 0 && (tj3Set(h, TJPARAM_DENSITYUNITS, 1) || tj3Set(h, TJPARAM_XDENSITY, dpi) || tj3Set(h, TJPARAM_YDENSITY, dpi))) rc = -1;
    if (!rc && icc && iccSize > 0 && tj3SetICCProfile(h, (unsigned char *)icc, iccSize)) rc = -1;
    *out = NULL; *outSize = 0;
    if (!rc && tj3Compress8(h, rgb, width, 0, height, TJPF_RGB, out, outSize)) rc = -1;
    if (rc) strncpy(err, tj3GetErrorStr(h), errLen);
    tj3Destroy(h);
    return rc;
}

void dr_jpeg_free(unsigned char *buf) { tj3Free(buf); }
