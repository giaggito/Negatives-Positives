#ifndef DR_JPEG_H
#define DR_JPEG_H
#include <stddef.h>

/// Encodes 8-bit interleaved RGB to JPEG with libjpeg-turbo (optimised Huffman tables, optional 4:4:4,
/// embedded ICC profile, print resolution `dpi` in the JFIF header). Returns 0 on success; `*out` must be
/// released with dr_jpeg_free.
int dr_jpeg_encode(const unsigned char *rgb, int width, int height, int quality, int chroma444, int dpi,
                   const unsigned char *icc, size_t iccSize, unsigned char **out, size_t *outSize,
                   char *err, int errLen);
void dr_jpeg_free(unsigned char *buf);

#endif
