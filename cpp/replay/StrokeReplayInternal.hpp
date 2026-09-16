#pragma once

#include "replay/StrokeReplay.hpp"

namespace margelo::nitro::inksignpdf::replay::detail {

PublishedGeometryMetrics measurePublishedGeometry(const Record& record);
std::vector<startup::StartupSection> buildEnvelopeSections(
    const std::vector<ModeledPoint>& centerline);
bool hasRealMovingDiagnostic(const Record& record);
BaselineMetrics measureBaseline(const Result& result);
bool validateStartupDiagnostics(const Result& result, std::string& error);
bool writeSvgArtifacts(const Result& result, const std::filesystem::path& directory,
                       StageSelection stages, std::string& error);
bool writeCsvArtifacts(const Result& result, const std::filesystem::path& directory,
                       StageSelection stages, std::string& error);

}  // namespace margelo::nitro::inksignpdf::replay::detail
