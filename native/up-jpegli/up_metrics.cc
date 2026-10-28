// SSIMULACRA2 score between two 8-bit sRGB images, via jpegli's tools/ssimulacra2.

#include <stdint.h>
#include <string.h>

#include <utility>

#include "lib/extras/packed_image.h"
#include "tools/ssimulacra2.h"
#include "up_jpegli.h"

namespace {

using jpegli::extras::PackedFrame;
using jpegli::extras::PackedPixelFile;

bool Fill(PackedPixelFile* file, const uint8_t* pixels, size_t stride, uint32_t width,
          uint32_t height, uint32_t components) {
  jpegli::extras::JpegliEncoderInitBasicInfo(&file->info);
  file->info.xsize = width;
  file->info.ysize = height;
  file->info.num_color_channels = components;
  file->info.bits_per_sample = 8;
  JpegliColorEncoding& c = file->color_encoding;
  c.color_space = components == 1 ? JPEGLI_COLOR_SPACE_GRAY : JPEGLI_COLOR_SPACE_RGB;
  c.white_point = JPEGLI_WHITE_POINT_D65;
  c.primaries = JPEGLI_PRIMARIES_SRGB;
  c.transfer_function = JPEGLI_TRANSFER_FUNCTION_SRGB;
  c.rendering_intent = JPEGLI_RENDERING_INTENT_PERCEPTUAL;
  JpegliPixelFormat format = {components, JPEGLI_TYPE_UINT8, JPEGLI_NATIVE_ENDIAN, 0};
  auto frame = PackedFrame::Create(width, height, format);
  if (!frame.ok()) return false;
  file->frames.emplace_back(std::move(frame).value_());
  PackedFrame& f = file->frames.back();
  for (uint32_t y = 0; y < height; ++y) {
    memcpy(f.color.pixels(y, 0, 0), pixels + static_cast<size_t>(y) * stride,
           static_cast<size_t>(width) * components);
  }
  return true;
}

}  // namespace

extern "C" UpjStatus upj_ssimulacra2(const uint8_t* reference, size_t reference_stride,
                                     const uint8_t* distorted, size_t distorted_stride,
                                     uint32_t width, uint32_t height, uint32_t components,
                                     double* score) {
  if (score == nullptr || reference == nullptr || distorted == nullptr || width < 8 ||
      height < 8 || (components != 1 && components != 3) ||
      reference_stride < static_cast<size_t>(width) * components ||
      distorted_stride < static_cast<size_t>(width) * components) {
    return UPJ_INVALID_ARGUMENT;
  }
  PackedPixelFile a;
  PackedPixelFile b;
  if (!Fill(&a, reference, reference_stride, width, height, components) ||
      !Fill(&b, distorted, distorted_stride, width, height, components)) {
    return UPJ_ENCODE_FAILED;
  }
  auto result = ComputeSSIMULACRA2(a, b);
  if (!result.ok()) return UPJ_ENCODE_FAILED;
  *score = std::move(result).value_().Score();
  return UPJ_OK;
}
