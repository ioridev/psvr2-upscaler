// Read-only OpenVR probe and opt-in, world-locked D3D11 test scene.
// Runtime sequencing follows Valve's IVRCompositor documentation:
// https://github.com/ValveSoftware/openvr/wiki/IVRCompositor_Overview
// This measures accepted submissions and compositor timing, not optical quality.
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi.h>
#include <wrl/client.h>
#include <openvr.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
using Microsoft::WRL::ComPtr;

static void Check(HRESULT hr, const char* operation) {
    if (FAILED(hr)) { std::ostringstream s; s << operation << ": HRESULT 0x" << std::hex << hr; throw std::runtime_error(s.str()); }
}
static std::string Quote(const std::string& s) {
    std::ostringstream out; out << '"';
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') out << '\\' << c;
        else if (c < 32) out << "\\u" << std::hex << std::setw(4) << std::setfill('0') << int(c);
        else out << c;
    }
    out << '"'; return out.str();
}
static std::string Narrow(const wchar_t* value) {
    const int count = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0, nullptr, nullptr);
    std::string s(count, '\0'); WideCharToMultiByte(CP_UTF8, 0, value, -1, s.data(), count, nullptr, nullptr);
    if (!s.empty()) s.pop_back(); return s;
}
static std::string Property(vr::IVRSystem* sys, vr::ETrackedDeviceProperty prop) {
    vr::ETrackedPropertyError error{};
    const auto count = sys->GetStringTrackedDeviceProperty(vr::k_unTrackedDeviceIndex_Hmd, prop, nullptr, 0, &error);
    if (!count) return {};
    std::vector<char> text(count); sys->GetStringTrackedDeviceProperty(0, prop, text.data(), count, &error);
    return error == vr::TrackedProp_Success ? text.data() : "";
}
struct Options {
    bool probe = false, distortionCoverage = false;
    double duration = 20, scale = .67;
    uint32_t panelWidth = 2000, panelHeight = 2040, coverageInputWidth = 0, coverageInputHeight = 0, coverageGrid = 41;
    std::string report = "vr-smoke.json";
};
struct CoverageChannel {
    uint64_t gridSamples = 0, failedSamples = 0, outOfBoundsSamples = 0, easuSamples = 0, nearThresholdSamples = 0;
    std::vector<double> singularValues;
};
struct DistortionCoverage {
    bool requested = false;
    uint32_t panelWidth = 0, panelHeight = 0, inputWidth = 0, inputHeight = 0, gridSize = 0;
    std::array<CoverageChannel, 6> channels;
    void Measure(vr::IVRSystem* sys, const Options& options, uint32_t recommendedWidth, uint32_t recommendedHeight) {
        requested = true; panelWidth = options.panelWidth; panelHeight = options.panelHeight; gridSize = options.coverageGrid;
        inputWidth = options.coverageInputWidth ? options.coverageInputWidth : uint32_t(std::lround(recommendedWidth * std::sqrt(options.scale)));
        inputHeight = options.coverageInputHeight ? options.coverageInputHeight : uint32_t(std::lround(recommendedHeight * std::sqrt(options.scale)));
        const float halfPixelX = .5f / panelWidth, halfPixelY = .5f / panelHeight;
        for (int eye = 0; eye < 2; ++eye) {
            for (uint32_t y = 0; y < gridSize; ++y) for (uint32_t x = 0; x < gridSize; ++x) {
                const float u = (x + .5f) / gridSize, v = (y + .5f) / gridSize;
                vr::DistortionCoordinates_t center{}, left{}, right{}, top{}, bottom{};
                const bool valid = sys->ComputeDistortion(vr::EVREye(eye), u, v, &center)
                    && sys->ComputeDistortion(vr::EVREye(eye), u - halfPixelX, v, &left)
                    && sys->ComputeDistortion(vr::EVREye(eye), u + halfPixelX, v, &right)
                    && sys->ComputeDistortion(vr::EVREye(eye), u, v - halfPixelY, &top)
                    && sys->ComputeDistortion(vr::EVREye(eye), u, v + halfPixelY, &bottom);
                const float* centers[] = {center.rfRed, center.rfGreen, center.rfBlue};
                const float* lefts[] = {left.rfRed, left.rfGreen, left.rfBlue};
                const float* rights[] = {right.rfRed, right.rfGreen, right.rfBlue};
                const float* tops[] = {top.rfRed, top.rfGreen, top.rfBlue};
                const float* bottoms[] = {bottom.rfRed, bottom.rfGreen, bottom.rfBlue};
                for (int channel = 0; channel < 3; ++channel) {
                    auto& s = channels[eye * 3 + channel]; ++s.gridSamples;
                    if (!valid) { ++s.failedSamples; continue; }
                    const double dx0 = (double(rights[channel][0]) - lefts[channel][0]) * inputWidth;
                    const double dx1 = (double(rights[channel][1]) - lefts[channel][1]) * inputHeight;
                    const double dy0 = (double(bottoms[channel][0]) - tops[channel][0]) * inputWidth;
                    const double dy1 = (double(bottoms[channel][1]) - tops[channel][1]) * inputHeight;
                    const double j00 = dx0 * dx0 + dx1 * dx1, j11 = dy0 * dy0 + dy1 * dy1, j01 = dx0 * dy0 + dx1 * dy1;
                    // Same largest singular value criterion as shaders/psvr2_easu.hlsl.
                    const double largestSquared = .5 * (j00 + j11 + std::sqrt(std::max(0., (j00-j11)*(j00-j11) + 4*j01*j01)));
                    const float* uv = centers[channel];
                    if (!std::isfinite(largestSquared) || !std::isfinite(uv[0]) || !std::isfinite(uv[1])) { ++s.failedSamples; continue; }
                    if (uv[0] < 0 || uv[0] > 1 || uv[1] < 0 || uv[1] > 1) { ++s.outOfBoundsSamples; continue; }
                    s.singularValues.push_back(std::sqrt(largestSquared));
                    if (largestSquared <= 1.0001) ++s.easuSamples;
                    if (std::abs(std::sqrt(largestSquared) - 1.) < .01) ++s.nearThresholdSamples;
                }
            }
        }
        for (auto& c : channels) std::sort(c.singularValues.begin(), c.singularValues.end());
    }
    void Save(std::ostream& o) const {
        o << "{\"requested\":" << requested;
        if (requested) {
            const bool allChannelsAvailable = std::all_of(channels.begin(), channels.end(), [](const CoverageChannel& c) { return !c.singularValues.empty(); });
            const bool allCallsSucceeded = std::all_of(channels.begin(), channels.end(), [](const CoverageChannel& c) { return c.failedSamples == 0; });
            o << ",\"allChannelsAvailable\":" << allChannelsAvailable << ",\"allCallsSucceeded\":" << allCallsSucceeded
              << ",\"method\":\"ComputeDistortion RGB central differences across one panel pixel; largest singular value squared <= 1.0001\""
              << ",\"assumedPanelPerEye\":{\"width\":" << panelWidth << ",\"height\":" << panelHeight << '}'
              << ",\"modelledInputPerEye\":{\"width\":" << inputWidth << ",\"height\":" << inputHeight << '}'
              << ",\"gridPerEye\":{\"width\":" << gridSize << ",\"height\":" << gridSize << '}'
              << ",\"channels\":[";
            const char* names[] = {"red", "green", "blue"};
            for (size_t i = 0; i < channels.size(); ++i) {
                if (i) o << ',';
                const auto& s = channels[i]; const auto& values = s.singularValues;
                o << "{\"eye\":" << Quote(i < 3 ? "left" : "right") << ",\"channel\":" << Quote(names[i % 3])
                  << ",\"gridSamples\":" << s.gridSamples << ",\"failedSamples\":" << s.failedSamples
                  << ",\"outOfBoundsSamples\":" << s.outOfBoundsSamples << ",\"inBoundsSamples\":" << values.size()
                  << ",\"estimatedEasuSamples\":" << s.easuSamples
                  << ",\"estimatedEasuFractionOfPanelGrid\":" << (s.gridSamples ? double(s.easuSamples) / s.gridSamples : 0.)
                  << ",\"estimatedEasuFractionOfInBoundsGrid\":" << (values.empty() ? 0. : double(s.easuSamples) / values.size())
                  << ",\"samplesWithinOnePercentOfThreshold\":" << s.nearThresholdSamples;
                if (!values.empty()) o << ",\"maxSingularValueMin\":" << values.front()
                    << ",\"maxSingularValueMedian\":" << values[values.size()/2] << ",\"maxSingularValueMax\":" << values.back();
                o << '}';
            }
            o << "],\"limitations\":\"Static mapping estimate, not measured shader invocation or optical visible-area coverage. Panel and input dimensions are assumptions. Excludes out-of-source UVs; does not apply hidden-area masks, timewarp, compositor mesh interpolation, or application-specific texture bounds. Values near threshold are sensitive to sampling and float precision.\"";
        }
        o << '}';
    }
};
struct Report {
    bool success = false, initialized = false, connected = false, poseValid = false, quit = false;
    std::string error, model, manufacturer, driver, actualDriver, resourceRoot, registeredType, driverVersion, gpu;
    std::string sceneImage = "world-locked quiet room, grid floor, stationary sphere";
    uint32_t recW = 0, recH = 0, width = 0, height = 0, initialScenePid = 0, finalScenePid = 0;
    int adapterIndex = -1, initError = 0; float hz = 0;
    uint64_t frames = 0, validPoses = 0, invalidPoses = 0, acceptedLeft = 0, acceptedRight = 0, acceptedStereo = 0;
    uint64_t waitErrors = 0, timingCount = 0, presented = 0, dropped = 0, mispresented = 0, reprojected = 0;
    uint64_t canRenderSceneFrames = 0, focusedSceneFrames = 0;
    double elapsed = 0, preGpu = 0, compGpu = 0, totalGpu = 0, compCpu = 0, clientInterval = 0;
    std::map<int, uint64_t> submitErrors;
    std::vector<vr::Compositor_FrameTiming> timings;
    DistortionCoverage coverage;
    vr::Compositor_CumulativeStats cumulativeStart{}, cumulativeEnd{};
    uint64_t vsyncCounterStart = 0, vsyncCounterEnd = 0;
    bool vsyncStartValid = false, vsyncEndValid = false;
    float sinceVsyncStart = 0, sinceVsyncEnd = 0;
    void Timing(vr::IVRCompositor* compositor) {
        vr::Compositor_FrameTiming t{}; t.m_nSize = sizeof(t);
        // Read a completed older entry; the newest frame may not have final GPU/present data.
        if (!compositor->GetFrameTiming(&t, 1)) return;
        if (!timings.empty() && timings.back().m_nFrameIndex == t.m_nFrameIndex) return;
        timings.push_back(t); ++timingCount;
        preGpu += t.m_flPreSubmitGpuMs; compGpu += t.m_flCompositorRenderGpuMs; totalGpu += t.m_flTotalRenderGpuMs;
        compCpu += t.m_flCompositorRenderCpuMs; clientInterval += t.m_flClientFrameIntervalMs;
        presented += t.m_nNumFramePresents; dropped += t.m_nNumDroppedFrames; mispresented += t.m_nNumMisPresented;
        if (t.m_nReprojectionFlags != 0) ++reprojected;
    }
    static void SaveCumulative(std::ostream& o, const vr::Compositor_CumulativeStats& s) {
        o << "{\"pid\":" << s.m_nPid << ",\"framePresents\":" << s.m_nNumFramePresents
          << ",\"droppedFrames\":" << s.m_nNumDroppedFrames << ",\"reprojectedFrames\":" << s.m_nNumReprojectedFrames
          << ",\"framePresentsOnStartup\":" << s.m_nNumFramePresentsOnStartup
          << ",\"droppedFramesOnStartup\":" << s.m_nNumDroppedFramesOnStartup
          << ",\"reprojectedFramesOnStartup\":" << s.m_nNumReprojectedFramesOnStartup
          << ",\"loadingCount\":" << s.m_nNumLoading << ",\"framePresentsLoading\":" << s.m_nNumFramePresentsLoading
          << ",\"droppedFramesLoading\":" << s.m_nNumDroppedFramesLoading << ",\"reprojectedFramesLoading\":" << s.m_nNumReprojectedFramesLoading
          << ",\"timedOutCount\":" << s.m_nNumTimedOut << ",\"framePresentsTimedOut\":" << s.m_nNumFramePresentsTimedOut
          << ",\"droppedFramesTimedOut\":" << s.m_nNumDroppedFramesTimedOut << ",\"reprojectedFramesTimedOut\":" << s.m_nNumReprojectedFramesTimedOut
          << ",\"frameSubmits\":" << s.m_nNumFrameSubmits
          << ",\"sumCompositorCpuMs\":" << s.m_flSumCompositorCPUTimeMS << ",\"sumCompositorGpuMs\":" << s.m_flSumCompositorGPUTimeMS
          << ",\"sumTargetFrameTimes\":" << s.m_flSumTargetFrameTimes
          << ",\"sumApplicationCpuMs\":" << s.m_flSumApplicationCPUTimeMS << ",\"sumApplicationGpuMs\":" << s.m_flSumApplicationGPUTimeMS
          << ",\"framesWithDepth\":" << s.m_nNumFramesWithDepth << '}';
    }
    void SaveInterval(std::ostream& o) const {
        const bool valid = elapsed > 0 && cumulativeStart.m_nPid != 0 && cumulativeStart.m_nPid == cumulativeEnd.m_nPid
            && cumulativeStart.m_nPid == initialScenePid && initialScenePid == finalScenePid
            && cumulativeEnd.m_nNumFrameSubmits >= cumulativeStart.m_nNumFrameSubmits
            && cumulativeEnd.m_nNumFramePresents >= cumulativeStart.m_nNumFramePresents
            && cumulativeEnd.m_nNumReprojectedFrames >= cumulativeStart.m_nNumReprojectedFrames
            && cumulativeEnd.m_nNumDroppedFrames >= cumulativeStart.m_nNumDroppedFrames;
        o << "{\"valid\":" << valid << ",\"start\":"; SaveCumulative(o, cumulativeStart);
        o << ",\"end\":"; SaveCumulative(o, cumulativeEnd);
        if (valid) {
            const auto submits = cumulativeEnd.m_nNumFrameSubmits - cumulativeStart.m_nNumFrameSubmits;
            const auto presents = cumulativeEnd.m_nNumFramePresents - cumulativeStart.m_nNumFramePresents;
            const auto reprojects = cumulativeEnd.m_nNumReprojectedFrames - cumulativeStart.m_nNumReprojectedFrames;
            const auto drops = cumulativeEnd.m_nNumDroppedFrames - cumulativeStart.m_nNumDroppedFrames;
            o << ",\"deltaFrameSubmits\":" << submits << ",\"deltaFramePresents\":" << presents
              << ",\"deltaReprojectedFrames\":" << reprojects << ",\"deltaDroppedFrames\":" << drops
              << ",\"applicationSubmitsPerSecond\":" << submits / elapsed << ",\"compositorPresentsPerSecond\":" << presents / elapsed
              << ",\"reprojectedFramesPerSecond\":" << reprojects / elapsed;
            if (submits) o << ",\"meanApplicationCpuMs\":" << (cumulativeEnd.m_flSumApplicationCPUTimeMS-cumulativeStart.m_flSumApplicationCPUTimeMS)/submits
                << ",\"meanApplicationGpuMs\":" << (cumulativeEnd.m_flSumApplicationGPUTimeMS-cumulativeStart.m_flSumApplicationGPUTimeMS)/submits
                << ",\"meanCompositorCpuMs\":" << (cumulativeEnd.m_flSumCompositorCPUTimeMS-cumulativeStart.m_flSumCompositorCPUTimeMS)/submits
                << ",\"meanCompositorGpuMs\":" << (cumulativeEnd.m_flSumCompositorGPUTimeMS-cumulativeStart.m_flSumCompositorGPUTimeMS)/submits
                << ",\"meanTargetFrameTime\":" << (cumulativeEnd.m_flSumTargetFrameTimes-cumulativeStart.m_flSumTargetFrameTimes)/submits;
        }
        o << ",\"counterVsyncStartValid\":" << vsyncStartValid << ",\"counterVsyncEndValid\":" << vsyncEndValid
          << ",\"counterVsyncStart\":" << vsyncCounterStart << ",\"counterVsyncEnd\":" << vsyncCounterEnd
          << ",\"secondsSinceVsyncStart\":" << sinceVsyncStart << ",\"secondsSinceVsyncEnd\":" << sinceVsyncEnd;
        if (vsyncStartValid && vsyncEndValid && vsyncCounterEnd >= vsyncCounterStart && elapsed > 0)
            o << ",\"vsyncCounterPerSecond\":" << (vsyncCounterEnd-vsyncCounterStart)/elapsed;
        o << '}';
    }
    void Save(const Options& options) const {
        std::ofstream o(options.report, std::ios::binary); if (!o) throw std::runtime_error("Cannot write report: " + options.report);
        const double n = timingCount ? double(timingCount) : 1.;
        o << std::boolalpha << std::setprecision(9)
          << "{\n  \"schemaVersion\": 1,\n  \"mode\": " << Quote(options.probe ? "probe" : "scene")
          << ",\n  \"success\": " << success << ",\n  \"error\": " << Quote(error)
          << ",\n  \"vrInitialized\": " << initialized << ",\n  \"vrInitError\": " << initError
          << ",\n  \"hmd\": {\"connected\": " << connected << ", \"poseValid\": " << poseValid
          << ", \"model\": " << Quote(model)
          << ", \"manufacturer\": " << Quote(manufacturer) << ", \"trackingSystem\": " << Quote(driver)
          << ", \"actualTrackingSystem\": " << Quote(actualDriver) << ", \"resourceRoot\": " << Quote(resourceRoot)
          << ", \"registeredDeviceType\": " << Quote(registeredType) << ", \"driverVersion\": " << Quote(driverVersion)
          << ", \"displayFrequencyHz\": " << hz << "},\n  \"adapter\": {\"index\": " << adapterIndex << ", \"name\": " << Quote(gpu)
          << "},\n  \"recommendedPerEye\": {\"width\": " << recW << ", \"height\": " << recH
          << "},\n  \"submittedPerEye\": {\"width\": " << width << ", \"height\": " << height
          << "},\n  \"pixelScaleRequested\": " << options.scale << ",\n  \"pixelScaleActual\": "
          << (recW && recH ? double(width) * height / (double(recW) * recH) : 0.)
          << ",\n  \"sceneImage\": " << Quote(sceneImage)
          << ",\n  \"initialSceneProcessId\": " << initialScenePid << ",\n  \"finalSceneProcessId\": " << finalScenePid
          << ",\n  \"requestedSeconds\": " << options.duration << ",\n  \"elapsedSeconds\": " << elapsed
          << ",\n  \"runtimeRequestedQuit\": " << quit << ",\n  \"frames\": " << frames
          << ",\n  \"validPoseFrames\": " << validPoses << ",\n  \"invalidPoseFrames\": " << invalidPoses
          << ",\n  \"acceptedLeft\": " << acceptedLeft << ",\n  \"acceptedRight\": " << acceptedRight
          << ",\n  \"acceptedStereoFrames\": " << acceptedStereo << ",\n  \"waitGetPosesErrors\": " << waitErrors
          << ",\n  \"canRenderSceneFrames\": " << canRenderSceneFrames << ",\n  \"focusedSceneFrames\": " << focusedSceneFrames
          << ",\n  \"submitErrorCounts\": {";
        bool first = true; for (const auto& e : submitErrors) { if (!first) o << ','; first = false; o << Quote(std::to_string(e.first)) << ':' << e.second; }
        o << "},\n  \"timing\": {\"uniqueSamples\": " << timingCount
          << ", \"meanPreSubmitGpuMs\": " << preGpu / n << ", \"meanCompositorGpuMs\": " << compGpu / n
          << ", \"meanTotalGpuMs\": " << totalGpu / n << ", \"meanCompositorCpuMs\": " << compCpu / n
          << ", \"meanClientFrameIntervalMs\": " << clientInterval / n
          << ", \"sampledPresents\": " << presented << ", \"sampledDroppedFrames\": " << dropped
          << ", \"sampledMispresents\": " << mispresented << ", \"samplesWithReprojectionFlags\": " << reprojected
          << ", \"sampleFramesAgo\": 1, \"pollIntervalMilliseconds\": " << (options.probe ? 8 : 0)
          << ", \"warning\": \"Unique samples per second is polling coverage, not application FPS. Use cumulativeInterval counters for rates. Nonzero flags alone do not mean a reused frame.\""
          << "},\n  \"cumulativeInterval\": "; SaveInterval(o);
        o << ",\n  \"timingSamples\": [";
        first = true; for (const auto& t : timings) {
            if (!first) o << ','; first = false;
            o << "\n    {\"frameIndex\":" << t.m_nFrameIndex << ",\"systemSeconds\":" << t.m_flSystemTimeInSeconds
              << ",\"preSubmitGpuMs\":" << t.m_flPreSubmitGpuMs << ",\"compositorGpuMs\":" << t.m_flCompositorRenderGpuMs
              << ",\"postSubmitGpuMs\":" << t.m_flPostSubmitGpuMs
              << ",\"compositorCpuMs\":" << t.m_flCompositorRenderCpuMs << ",\"compositorIdleCpuMs\":" << t.m_flCompositorIdleCpuMs
              << ",\"clientFrameIntervalMs\":" << t.m_flClientFrameIntervalMs << ",\"presentCallCpuMs\":" << t.m_flPresentCallCpuMs
              << ",\"waitForPresentCpuMs\":" << t.m_flWaitForPresentCpuMs << ",\"submitFrameMs\":" << t.m_flSubmitFrameMs
              << ",\"waitGetPosesCalledMs\":" << t.m_flWaitGetPosesCalledMs << ",\"newPosesReadyMs\":" << t.m_flNewPosesReadyMs
              << ",\"newFrameReadyMs\":" << t.m_flNewFrameReadyMs << ",\"compositorUpdateStartMs\":" << t.m_flCompositorUpdateStartMs
              << ",\"compositorUpdateEndMs\":" << t.m_flCompositorUpdateEndMs << ",\"compositorRenderStartMs\":" << t.m_flCompositorRenderStartMs
              << ",\"totalGpuMs\":" << t.m_flTotalRenderGpuMs << ",\"presents\":" << t.m_nNumFramePresents
              << ",\"mispresents\":" << t.m_nNumMisPresented << ",\"dropped\":" << t.m_nNumDroppedFrames
              << ",\"vsyncsReadyForUse\":" << t.m_nNumVSyncsReadyForUse << ",\"vsyncsToFirstView\":" << t.m_nNumVSyncsToFirstView
              << ",\"transferLatencyMs\":" << t.m_flTransferLatencyMs << ",\"reprojectionFlags\":" << t.m_nReprojectionFlags
              << ",\"reusedReasonCpu\":" << bool(t.m_nReprojectionFlags & vr::VRCompositor_ReprojectionReason_Cpu)
              << ",\"reusedReasonGpu\":" << bool(t.m_nReprojectionFlags & vr::VRCompositor_ReprojectionReason_Gpu)
              << ",\"asyncModeActive\":" << bool(t.m_nReprojectionFlags & vr::VRCompositor_ReprojectionAsync)
              << ",\"motionSmoothingTriggered\":" << bool(t.m_nReprojectionFlags & vr::VRCompositor_ReprojectionMotion)
              << ",\"additionalPredictedFrames\":" << VR_COMPOSITOR_ADDITIONAL_PREDICTED_FRAMES(t)
              << ",\"throttledFrames\":" << VR_COMPOSITOR_NUMBER_OF_THROTTLED_FRAMES(t) << '}';
        }
        o << "\n  ],\n  \"distortionCoverage\": "; coverage.Save(o);
        o << ",\n  \"limitations\": \"Submissions and runtime timings do not prove optical quality or driver shader execution. Probe timings belong to the runtime's active scene and are sampled, not exhaustive.\"\n}\n";
        if (!o) throw std::runtime_error("Report write failed: " + options.report);
    }
};

const char* shader = R"HLSL(
cbuffer Camera : register(b0) { float4 row0; float4 row1; float4 row2; float4 frustum; };
struct V { float4 p:SV_Position; float2 uv:TEXCOORD0; };
V VS(uint id:SV_VertexID) { V o; o.uv=float2((id<<1)&2,id&2); o.p=float4(o.uv.x*2-1,1-o.uv.y*2,0,1); return o; }
float4 PS(V input):SV_Target {
    float3 er=normalize(float3(lerp(frustum.x,frustum.y,input.uv.x),-lerp(frustum.z,frustum.w,input.uv.y),-1));
    float3 ro=float3(row0.w,row1.w,row2.w);
    float3 rd=normalize(float3(dot(row0.xyz,er),dot(row1.xyz,er),dot(row2.xyz,er)));
    float best=100; float3 color=float3(.08,.10,.13);
    // Stationary floor grid, with antialiasing at distance.
    if (abs(rd.y)>.0001) {
        float t=-ro.y/rd.y;
        if(t>0 && t<best) {
            best=t; float2 p=(ro+rd*t).xz;
            float2 g=abs(frac(p-.5)-.5)/max(fwidth(p),.002);
            float grid=1-saturate(min(g.x,g.y));
            color=lerp(float3(.15,.17,.19),float3(.32,.36,.39),grid);
            color=lerp(float3(.10,.12,.15),color,exp(-t*.025));
        }
    }
    // Quiet, world-locked room walls at +/-4 meters; never full-field flashing.
    for(int axis=0;axis<2;axis++) for(int side=-1;side<=1;side+=2) {
        float d=axis==0?rd.x:rd.z, r=axis==0?ro.x:ro.z;
        float t=(side*4-r)/d; float3 p=ro+rd*t;
        if(abs(d)>.0001 && t>0 && t<best && p.y>=0 && p.y<4 && abs(axis==0?p.z:p.x)<=4) {
            best=t; float2 uv=float2(axis==0?p.z:p.x,p.y);
            float2 g=abs(frac(uv-.5)-.5)/max(fwidth(uv),.002);
            float grid=1-saturate(min(g.x,g.y));
            color=lerp(float3(.16,.18,.22),float3(.25,.29,.33),grid);
            float stripe=1-smoothstep(.005,.02,abs(p.y-1.5));
            color=lerp(color,float3(.13,.32,.35),stripe);
        }
    }
    float3 oc=ro-float3(0,1.25,-2); float b=dot(oc,rd), c=dot(oc,oc)-.25;
    float h=b*b-c;
    if(h>0) { float t=-b-sqrt(h); if(t>0 && t<best) {
        float3 n=normalize(ro+rd*t-float3(0,1.25,-2));
        color=float3(.24,.50,.58)*(.35+.65*saturate(dot(n,normalize(float3(-1,2,1)))));
        color+=float3(.12,.14,.13)*step(.92,abs(sin(atan2(n.x,n.z)*12)));
    }}
    return float4(color,1);
}
)HLSL";

static ComPtr<ID3DBlob> CompileShader(const char* entry,const char* profile) {
    ComPtr<ID3DBlob> blob,errors;
    const HRESULT hr=D3DCompile(shader,strlen(shader),"vr_smoke",nullptr,nullptr,entry,profile,
        D3DCOMPILE_ENABLE_STRICTNESS|D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&blob,&errors);
    if(FAILED(hr)) throw std::runtime_error(errors ? std::string((char*)errors->GetBufferPointer(),errors->GetBufferSize()) : "Shader compilation failed");
    return blob;
}

struct Renderer {
    ComPtr<ID3D11Device> device; ComPtr<ID3D11DeviceContext> context;
    ComPtr<ID3D11VertexShader> vs; ComPtr<ID3D11PixelShader> ps; ComPtr<ID3D11Buffer> constants;
    ComPtr<ID3D11RasterizerState> raster;
    std::array<ComPtr<ID3D11Texture2D>, 2> texture;
    std::array<ComPtr<ID3D11RenderTargetView>, 2> target;
    Renderer(vr::IVRSystem* sys, Report& report, double scale) {
        sys->GetDXGIOutputInfo(&report.adapterIndex);
        if(report.adapterIndex<0) throw std::runtime_error("Runtime did not identify a DXGI adapter");
        ComPtr<IDXGIFactory1> factory; Check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)), "CreateDXGIFactory1");
        ComPtr<IDXGIAdapter1> adapter; Check(factory->EnumAdapters1(report.adapterIndex, &adapter), "EnumAdapters1");
        DXGI_ADAPTER_DESC1 desc{}; Check(adapter->GetDesc1(&desc), "GetDesc1"); report.gpu=Narrow(desc.Description);
        D3D_FEATURE_LEVEL levels[]={D3D_FEATURE_LEVEL_11_0};
        Check(D3D11CreateDevice(adapter.Get(),D3D_DRIVER_TYPE_UNKNOWN,nullptr,0,levels,1,D3D11_SDK_VERSION,&device,nullptr,&context),"D3D11CreateDevice");
        report.width=std::max(16u,uint32_t(std::lround(report.recW*std::sqrt(scale))));
        report.height=std::max(16u,uint32_t(std::lround(report.recH*std::sqrt(scale))));
        D3D11_TEXTURE2D_DESC td{}; td.Width=report.width; td.Height=report.height; td.MipLevels=td.ArraySize=1;
        td.Format=DXGI_FORMAT_R8G8B8A8_UNORM; td.SampleDesc.Count=1; td.Usage=D3D11_USAGE_DEFAULT;
        td.BindFlags=D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE;
        for (int eye=0;eye<2;++eye) {
            Check(device->CreateTexture2D(&td,nullptr,&texture[eye]),"CreateTexture2D");
            Check(device->CreateRenderTargetView(texture[eye].Get(),nullptr,&target[eye]),"CreateRenderTargetView");
        }
        const auto v=CompileShader("VS","vs_5_0"),p=CompileShader("PS","ps_5_0");
        Check(device->CreateVertexShader(v->GetBufferPointer(),v->GetBufferSize(),nullptr,&vs),"CreateVertexShader");
        Check(device->CreatePixelShader(p->GetBufferPointer(),p->GetBufferSize(),nullptr,&ps),"CreatePixelShader");
        D3D11_BUFFER_DESC cb{}; cb.ByteWidth=64; cb.Usage=D3D11_USAGE_DEFAULT; cb.BindFlags=D3D11_BIND_CONSTANT_BUFFER;
        Check(device->CreateBuffer(&cb,nullptr,&constants),"CreateBuffer");
        D3D11_RASTERIZER_DESC rs{}; rs.FillMode=D3D11_FILL_SOLID; rs.CullMode=D3D11_CULL_NONE; rs.DepthClipEnable=TRUE;
        Check(device->CreateRasterizerState(&rs,&raster),"CreateRasterizerState");
        D3D11_VIEWPORT viewport{0,0,float(report.width),float(report.height),0,1}; context->RSSetViewports(1,&viewport);
        context->RSSetState(raster.Get()); context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        context->VSSetShader(vs.Get(),nullptr,0); context->PSSetShader(ps.Get(),nullptr,0);
        ID3D11Buffer* cbPtr=constants.Get(); context->PSSetConstantBuffers(0,1,&cbPtr);
    }
    void Draw(vr::IVRSystem* sys,const vr::HmdMatrix34_t& headToWorld,int eye) {
        const auto eyeToHead=sys->GetEyeToHeadTransform(vr::EVREye(eye));
        float data[16]{};
        for(int r=0;r<3;++r) {
            for(int c=0;c<3;++c) for(int k=0;k<3;++k) data[r*4+c]+=headToWorld.m[r][k]*eyeToHead.m[k][c];
            data[r*4+3]=headToWorld.m[r][3];
            for(int k=0;k<3;++k) data[r*4+3]+=headToWorld.m[r][k]*eyeToHead.m[k][3];
        }
        sys->GetProjectionRaw(vr::EVREye(eye),&data[12],&data[13],&data[14],&data[15]);
        context->UpdateSubresource(constants.Get(),0,nullptr,data,0,0);
        ID3D11RenderTargetView* rt=target[eye].Get(); context->OMSetRenderTargets(1,&rt,nullptr); context->Draw(3,0);
    }
};

int main(int argc,char** argv) {
    // Offline check: no OpenVR initialization, device creation, or HMD activity.
    if(argc==2 && std::string(argv[1])=="--validate-shaders") {
        try {
            CompileShader("VS","vs_5_0"); CompileShader("PS","ps_5_0");
            std::cout << "PASS D3D11 scene shaders compiled; OpenVR was not initialized\n"; return 0;
        } catch(const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
    }
    Options options; Report report; bool vrOpen=false;
    try {
        for(int i=1;i<argc;++i) {
            const std::string a=argv[i];
            if(a=="--probe") options.probe=true;
            else if(a=="--distortion-coverage") options.distortionCoverage=true;
            else if(a=="--duration" && i+1<argc) options.duration=std::stod(argv[++i]);
            else if(a=="--pixel-scale" && i+1<argc) options.scale=std::stod(argv[++i]);
            else if(a=="--panel-width" && i+1<argc) options.panelWidth=uint32_t(std::stoul(argv[++i]));
            else if(a=="--panel-height" && i+1<argc) options.panelHeight=uint32_t(std::stoul(argv[++i]));
            else if(a=="--coverage-input-width" && i+1<argc) options.coverageInputWidth=uint32_t(std::stoul(argv[++i]));
            else if(a=="--coverage-input-height" && i+1<argc) options.coverageInputHeight=uint32_t(std::stoul(argv[++i]));
            else if(a=="--coverage-grid" && i+1<argc) options.coverageGrid=uint32_t(std::stoul(argv[++i]));
            else if(a=="--report" && i+1<argc) options.report=argv[++i];
            else throw std::runtime_error("Usage: psvr2_vr_smoke [--probe] [--duration 20] [--pixel-scale .67] [--report path]");
        }
        if(!std::isfinite(options.duration) || options.duration<.1 || options.duration>600 || !std::isfinite(options.scale) || options.scale<.05 || options.scale>2)
            throw std::runtime_error("duration must be 0.1..600 seconds; pixel-scale must be 0.05..2");
        if(options.panelWidth<16 || options.panelWidth>32768 || options.panelHeight<16 || options.panelHeight>32768
            || options.coverageInputWidth>32768 || options.coverageInputHeight>32768
            || bool(options.coverageInputWidth)!=bool(options.coverageInputHeight) || options.coverageGrid<9 || options.coverageGrid>129)
            throw std::runtime_error("panel dimensions must be 16..32768; coverage input dimensions must both be zero or 1..32768; coverage grid must be 9..129");
        vr::EVRInitError init{};
        auto* sys=vr::VR_Init(&init,options.probe?vr::VRApplication_Background:vr::VRApplication_Scene);
        report.initError=int(init);
        if(init!=vr::VRInitError_None || !sys) throw std::runtime_error(vr::VR_GetVRInitErrorAsEnglishDescription(init));
        vrOpen=true; report.initialized=true;
        report.connected=sys->IsTrackedDeviceConnected(0);
        report.model=Property(sys,vr::Prop_ModelNumber_String);
        report.manufacturer=Property(sys,vr::Prop_ManufacturerName_String); report.driver=Property(sys,vr::Prop_TrackingSystemName_String);
        // Prop 1000 and model/manufacturer can be spoofed per application for compatibility.
        // 1054 is the runtime's literal local driver name, independent of Prop 1000.
        report.actualDriver=Property(sys,vr::Prop_ActualTrackingSystemName_String);
        report.resourceRoot=Property(sys,vr::Prop_ResourceRoot_String);
        report.registeredType=Property(sys,vr::Prop_RegisteredDeviceType_String);
        report.driverVersion=Property(sys,vr::Prop_DriverVersion_String);
        report.hz=sys->GetFloatTrackedDeviceProperty(0,vr::Prop_DisplayFrequency_Float);
        sys->GetRecommendedRenderTargetSize(&report.recW,&report.recH);
        auto* compositor=vr::VRCompositor();
        if(!report.connected) throw std::runtime_error("No connected HMD; no scene submitted");
        if(!compositor) throw std::runtime_error("IVRCompositor unavailable");
        report.initialScenePid=compositor->GetCurrentSceneFocusProcess();
        if(options.distortionCoverage) report.coverage.Measure(sys, options, report.recW, report.recH);
        std::unique_ptr<Renderer> renderer;
        if(!options.probe) {
            compositor->SetTrackingSpace(vr::TrackingUniverseStanding);
            renderer=std::make_unique<Renderer>(sys,report,options.scale);
        }
        const auto begin=std::chrono::steady_clock::now();
        compositor->GetCumulativeStats(&report.cumulativeStart, sizeof(report.cumulativeStart));
        report.vsyncStartValid = sys->GetTimeSinceLastVsync(&report.sinceVsyncStart, &report.vsyncCounterStart);
        auto seconds=[&] { return std::chrono::duration<double>(std::chrono::steady_clock::now()-begin).count(); };
        std::array<vr::TrackedDevicePose_t,vr::k_unMaxTrackedDeviceCount> poses{};
        while(seconds()<options.duration) {
            vr::VREvent_t event{};
            while(sys->PollNextEvent(&event,sizeof(event))) if(event.eventType==vr::VREvent_Quit) { report.quit=true; sys->AcknowledgeQuit_Exiting(); }
            if(report.quit) break;
            if(options.probe) {
                compositor->GetLastPoses(poses.data(),uint32_t(poses.size()),nullptr,0);
                report.poseValid=poses[0].bPoseIsValid && poses[0].bDeviceIsConnected;
                if(report.poseValid) ++report.validPoses; else ++report.invalidPoses;
                report.Timing(compositor); std::this_thread::sleep_for(std::chrono::milliseconds(8));
            } else {
                ++report.frames;
                auto wait=compositor->WaitGetPoses(poses.data(),uint32_t(poses.size()),nullptr,0);
                if(wait!=vr::VRCompositorError_None) { ++report.waitErrors; std::this_thread::sleep_for(std::chrono::milliseconds(10)); continue; }
                report.poseValid=poses[0].bPoseIsValid && poses[0].bDeviceIsConnected;
                if(!report.poseValid) { ++report.invalidPoses; std::this_thread::sleep_for(std::chrono::milliseconds(10)); continue; }
                ++report.validPoses;
                if(compositor->CanRenderScene()) ++report.canRenderSceneFrames;
                if(compositor->GetCurrentSceneFocusProcess()==GetCurrentProcessId()) ++report.focusedSceneFrames;
                bool stereoAccepted=true;
                for(int eye=0;eye<2;++eye) {
                    renderer->Draw(sys,poses[0].mDeviceToAbsoluteTracking,eye);
                    vr::Texture_t tex{renderer->texture[eye].Get(),vr::TextureType_DirectX,vr::ColorSpace_Gamma};
                    const auto result=compositor->Submit(vr::EVREye(eye),&tex);
                    if(result==vr::VRCompositorError_None) { if(eye==0) ++report.acceptedLeft; else ++report.acceptedRight; }
                    else { ++report.submitErrors[int(result)]; stereoAccepted=false; }
                }
                if(stereoAccepted) ++report.acceptedStereo;
                renderer->context->Flush(); compositor->PostPresentHandoff(); report.Timing(compositor);
            }
        }
        compositor->GetCumulativeStats(&report.cumulativeEnd, sizeof(report.cumulativeEnd));
        report.vsyncEndValid = sys->GetTimeSinceLastVsync(&report.sinceVsyncEnd, &report.vsyncCounterEnd);
        report.elapsed=seconds(); report.connected=sys->IsTrackedDeviceConnected(0);
        report.finalScenePid=compositor->GetCurrentSceneFocusProcess();
        report.success=report.connected && !report.quit && (options.probe ||
            (report.acceptedStereo>=10 && report.submitErrors.empty() && report.waitErrors==0 && report.validPoses>0 && report.timingCount>0 && report.canRenderSceneFrames>0 && report.focusedSceneFrames>0));
        if(!report.success) report.error="HMD disconnected, runtime quit, tracking unavailable, rejected submissions, scene unfocused/hidden, or insufficient accepted/timed frames";
        // Release scene textures while the runtime connection is still alive.
        renderer.reset();
    } catch(const std::exception& e) { report.error=e.what(); report.success=false; }
    if(vrOpen) vr::VR_Shutdown();
    try { report.Save(options); } catch(const std::exception& e) { std::cerr << e.what() << '\n'; return 2; }
    std::cout << (report.success?"PASS":"FAIL") << " mode=" << (options.probe?"probe":"scene")
              << " model=" << report.model << " acceptedStereo=" << report.acceptedStereo
              << " timingSamples=" << report.timingCount << " report=" << options.report << '\n';
    if(!report.error.empty()) std::cerr << report.error << '\n';
    return report.success?0:1;
}
