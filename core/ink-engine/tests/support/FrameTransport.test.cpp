#include "InkEngine.hpp"
#include "ink-engine/tests/fixtures/StrokeFixtures.hpp"
#include "ink-engine/tests/support/FrameTransport.hpp"
#include "ink-engine/tests/support/TestSupport.hpp"

#include <cmath>

using namespace margelo::nitro::inksignpdf;
using namespace margelo::nitro::inksignpdf::detail;

int main() {
  InkEngine engine({.smoothing = 0.0});
  InkStrokeFrame frame;
  FrameTransport transport;
  std::uint64_t previousRevision = 0;
  const auto fixture = fixtures::all().front();
  for (const auto& input : fixture.inputs) {
    const auto status = input.eventType == InkStrokeEventType::Down
        ? engine.begin(input, frame)
        : input.eventType == InkStrokeEventType::Move
            ? engine.update(input, frame)
            : engine.end(input, frame);
    CHECK(status.ok());
    const auto& view = frame.isFinal()
        ? transport.replaceFinal(frame.revision, frame.committedPointCount,
                                 frame.contours)
        : transport.replace(frame);
    CHECK(view.type == (frame.isFinal() ? InkEngineFrameTypeFinal
                                         : InkEngineFrameTypeCommitted));
    CHECK(view.contourCount == frame.contours.size());
    for (std::size_t i = 0; i < view.contourCount; ++i) {
      CHECK(view.contours[i].segmentStart + view.contours[i].segmentCount <=
            view.segmentCount);
      CHECK(view.contours[i].sourceStart <= view.contours[i].sourceEnd);
    }
    previousRevision = view.revision;
  }
  CHECK(frame.isFinal());
  const auto& final = transport.replaceFinal(
      previousRevision + 1, frame.committedPointCount, frame.contours);
  CHECK(final.type == InkEngineFrameTypeFinal);
  CHECK(final.contourCount == frame.contours.size());
  CHECK(final.segmentCount > 0);
  transport.clear();
  CHECK(transport.view().revision == 0);
  CHECK(transport.view().contourCount == 0);
  return 0;
}
