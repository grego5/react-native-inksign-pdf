#pragma once

#include "core/StrokeOutline.hpp"
#include "upstream/UpstreamStrokeGeometry.hpp"

#include <cstddef>

namespace margelo::nitro::inksignpdf {

// Converts an owned upstream mesh/outline snapshot into the native path
// transport. This is a representation adapter only; it does not construct or
// repair geometry.
StrokeContourCollection extractUpstreamContours(
    const UpstreamStrokeGeometry::Snapshot& snapshot, std::size_t sourceEnd);

StrokeContourCollection extractUpstreamContours(
    const UpstreamStrokeGeometry& geometry, std::size_t sourceEnd);

}  // namespace margelo::nitro::inksignpdf
