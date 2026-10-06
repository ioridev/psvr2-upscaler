// Offscreen D3D11 verification. This never starts or modifies SteamVR.
#define NOMINMAX
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi.h>
#include <wrl/client.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <numeric>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
using Microsoft::WRL::ComPtr;
namespace fs = std::filesystem;

static void Check(HRESULT result, const char* operation) {
    if (FAILED(result)) throw std::runtime_error(std::string(operation) + " failed: " + std::to_string(result));
}
struct Pixel { float r, g, b, a; };
struct Image {
    unsigned width, height;
    std::vector<Pixel> pixels;
    Image(unsigned w, unsigned h, Pixel value = {}) : width(w), height(h), pixels(size_t(w) * h, value) {}
    Pixel& at(unsigned x, unsigned y) { return pixels[size_t(y) * width + x]; }
};
struct alignas(16) Params {
    float input[2], output[2], bounds[4];
    unsigned easu, gamma;
    float padding[2]{};
    float transform[4]{1, 0, 0, 1};
};
struct TestResult { std::string name; double value, tolerance; bool passed, atLeast; };

class Gpu {
public:
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<ID3D11VertexShader> vs;
    ComPtr<ID3D11PixelShader> ps;
    ComPtr<ID3D11SamplerState> sampler;
    ComPtr<ID3D11Buffer> constants;
    std::string adapterName;
    bool upstreamAvailable = false;
    Gpu(const fs::path& shader) {
        D3D_FEATURE_LEVEL supported{};
        const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_0};
        Check(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, levels, 1,
            D3D11_SDK_VERSION, &device, &supported, &context), "create hardware D3D11 device");
        ComPtr<IDXGIDevice> dxgi; Check(device.As(&dxgi), "get DXGI device");
        ComPtr<IDXGIAdapter> adapter; Check(dxgi->GetAdapter(&adapter), "get adapter");
        DXGI_ADAPTER_DESC desc{}; Check(adapter->GetDesc(&desc), "get adapter description");
        const std::wstring wideName(desc.Description);
        int utf8Size = WideCharToMultiByte(CP_UTF8, 0, wideName.c_str(), int(wideName.size()), nullptr, 0, nullptr, nullptr);
        adapterName.resize(utf8Size);
        WideCharToMultiByte(CP_UTF8, 0, wideName.c_str(), int(wideName.size()), adapterName.data(), utf8Size, nullptr, nullptr);
        upstreamAvailable = fs::exists(shader.parent_path() / "../research/FidelityFX-FSR/ffx-fsr/ffx_fsr1.h");
        const D3D_SHADER_MACRO upstreamMacro[] = {{"TEST_UPSTREAM", "1"}, {nullptr, nullptr}};
        auto compile = [&](const char* entry, const char* profile) {
            ComPtr<ID3DBlob> code, errors;
            HRESULT result = D3DCompileFromFile(shader.c_str(), upstreamAvailable ? upstreamMacro : nullptr, D3D_COMPILE_STANDARD_FILE_INCLUDE,
                entry, profile, D3DCOMPILE_ENABLE_STRICTNESS | D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &code, &errors);
            if (errors) std::cerr.write(static_cast<const char*>(errors->GetBufferPointer()), errors->GetBufferSize());
            Check(result, entry); return code;
        };
        auto vertex = compile("VS", "vs_5_0"); auto pixel = compile("PS", "ps_5_0");
        Check(device->CreateVertexShader(vertex->GetBufferPointer(), vertex->GetBufferSize(), nullptr, &vs), "vertex shader");
        Check(device->CreatePixelShader(pixel->GetBufferPointer(), pixel->GetBufferSize(), nullptr, &ps), "pixel shader");
        D3D11_SAMPLER_DESC sd{}; sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        sd.AddressU = sd.AddressV = sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
        sd.MaxLOD = D3D11_FLOAT32_MAX;
        Check(device->CreateSamplerState(&sd, &sampler), "sampler");
        D3D11_BUFFER_DESC bd{}; bd.ByteWidth = sizeof(Params); bd.Usage = D3D11_USAGE_DEFAULT;
        bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        Check(device->CreateBuffer(&bd, nullptr, &constants), "constant buffer");
    }
    Image render(const Image& input, unsigned outWidth, unsigned outHeight, unsigned easu, bool gamma,
        std::array<float, 4> bounds = {0, 0, 1, 1}, double* ms = nullptr, unsigned repeats = 1,
        std::array<float, 4> transform = {1, 0, 0, 1}) {
        D3D11_TEXTURE2D_DESC td{}; td.Width = input.width; td.Height = input.height;
        td.MipLevels = td.ArraySize = 1; td.Format = DXGI_FORMAT_R32G32B32A32_FLOAT;
        td.SampleDesc.Count = 1; td.Usage = D3D11_USAGE_IMMUTABLE; td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
        D3D11_SUBRESOURCE_DATA init{}; init.pSysMem = input.pixels.data(); init.SysMemPitch = input.width * sizeof(Pixel);
        ComPtr<ID3D11Texture2D> source; Check(device->CreateTexture2D(&td, &init, &source), "source texture");
        ComPtr<ID3D11ShaderResourceView> srv; Check(device->CreateShaderResourceView(source.Get(), nullptr, &srv), "source view");
        td.Width = outWidth; td.Height = outHeight; td.Usage = D3D11_USAGE_DEFAULT;
        td.BindFlags = D3D11_BIND_RENDER_TARGET;
        ComPtr<ID3D11Texture2D> target; Check(device->CreateTexture2D(&td, nullptr, &target), "target texture");
        ComPtr<ID3D11RenderTargetView> rtv; Check(device->CreateRenderTargetView(target.Get(), nullptr, &rtv), "target view");
        td.Usage = D3D11_USAGE_STAGING; td.BindFlags = 0; td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        ComPtr<ID3D11Texture2D> staging; Check(device->CreateTexture2D(&td, nullptr, &staging), "staging texture");
        Params p{{float(input.width), float(input.height)}, {float(outWidth), float(outHeight)},
            {bounds[0], bounds[1], bounds[2], bounds[3]}, unsigned(easu), unsigned(gamma)};
        std::copy(transform.begin(), transform.end(), p.transform);
        context->UpdateSubresource(constants.Get(), 0, nullptr, &p, 0, 0);
        ID3D11Buffer* cb = constants.Get(); ID3D11SamplerState* sm = sampler.Get();
        ID3D11ShaderResourceView* resource = srv.Get(); ID3D11RenderTargetView* view = rtv.Get();
        context->IASetInputLayout(nullptr); context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        context->VSSetShader(vs.Get(), nullptr, 0); context->PSSetShader(ps.Get(), nullptr, 0);
        context->PSSetConstantBuffers(0, 1, &cb); context->PSSetSamplers(0, 1, &sm); context->PSSetShaderResources(0, 1, &resource);
        context->OMSetRenderTargets(1, &view, nullptr);
        D3D11_VIEWPORT viewport{0, 0, float(outWidth), float(outHeight), 0, 1}; context->RSSetViewports(1, &viewport);
        ComPtr<ID3D11Query> disjoint, begin, end;
        if (ms) {
            D3D11_QUERY_DESC qd{D3D11_QUERY_TIMESTAMP_DISJOINT, 0}; Check(device->CreateQuery(&qd, &disjoint), "disjoint query");
            qd.Query = D3D11_QUERY_TIMESTAMP;
            Check(device->CreateQuery(&qd, &begin), "start query"); Check(device->CreateQuery(&qd, &end), "end query");
            context->Draw(3, 0); // Warm the shader and resource; excluded from timestamp.
            context->Begin(disjoint.Get()); context->End(begin.Get());
        }
        for (unsigned i = 0; i < repeats; ++i) context->Draw(3, 0);
        if (ms) { context->End(end.Get()); context->End(disjoint.Get()); }
        context->CopyResource(staging.Get(), target.Get());
        D3D11_MAPPED_SUBRESOURCE mapped{}; Check(context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped), "readback");
        Image output(outWidth, outHeight);
        for (unsigned y = 0; y < outHeight; ++y)
            memcpy(output.pixels.data() + size_t(y) * outWidth, static_cast<const char*>(mapped.pData) + size_t(y) * mapped.RowPitch, outWidth * sizeof(Pixel));
        context->Unmap(staging.Get(), 0);
        if (ms) {
            auto get = [&](ID3D11Query* query, void* data, unsigned size) {
                const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
                HRESULT result;
                while ((result = context->GetData(query, data, size, 0)) == S_FALSE) {
                    if (std::chrono::steady_clock::now() > deadline) throw std::runtime_error("GPU query timeout");
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                }
                Check(result, "GPU timestamp readback");
            };
            D3D11_QUERY_DATA_TIMESTAMP_DISJOINT data{}; UINT64 first{}, last{};
            get(disjoint.Get(), &data, sizeof(data)); get(begin.Get(), &first, sizeof(first)); get(end.Get(), &last, sizeof(last));
            if (data.Disjoint || !data.Frequency) throw std::runtime_error("GPU timestamps were disjoint");
            *ms = double(last - first) * 1000.0 / double(data.Frequency) / repeats;
        }
        resource = nullptr; context->PSSetShaderResources(0, 1, &resource); context->OMSetRenderTargets(0, nullptr, nullptr);
        return output;
    }
};

static double Difference(const Image& a, const Image& b, bool maximum, bool alphaOnly = false) {
    double value = 0;
    for (size_t i = 0; i < a.pixels.size(); ++i) {
        const float* x = &a.pixels[i].r; const float* y = &b.pixels[i].r;
        for (unsigned c = alphaOnly ? 3u : 0u; c < 4; ++c) {
            const double d = std::abs(double(x[c]) - y[c]); value = maximum ? std::max(value, d) : value + d;
        }
    }
    return maximum ? value : value / (a.pixels.size() * (alphaOnly ? 1 : 4));
}
static double Nonfinite(const Image& image) {
    double count = 0; for (const auto& p : image.pixels) for (float v : {p.r, p.g, p.b, p.a}) if (!std::isfinite(v)) ++count;
    return count;
}
static double OutOfRange(const Image& image, float minimum, float maximum) {
    double excursion = 0;
    for (const auto& p : image.pixels) for (float value : {p.r, p.g, p.b})
        excursion = std::max({excursion, double(minimum - value), double(value - maximum)});
    return excursion;
}
static Image Pattern(unsigned width, unsigned height) {
    Image image(width, height);
    for (unsigned y = 0; y < height; ++y) for (unsigned x = 0; x < width; ++x) {
        const float diagonal = x * 3 > y * 4 + width / 4 ? 0.95f : 0.05f;
        const float grid = ((x / 3 + y / 5) % 2) ? 0.8f : 0.12f;
        image.at(x, y) = {diagonal, grid, ((x + 2 * y) % 11 < 3) ? 0.9f : 0.1f, float(x) / std::max(1u, width - 1)};
    }
    return image;
}
static void Bitmap(const fs::path& path, const Image& image) {
    const unsigned stride = (image.width * 3 + 3) & ~3u;
    BITMAPFILEHEADER file{}; file.bfType = 0x4d42; file.bfOffBits = sizeof(file) + sizeof(BITMAPINFOHEADER); file.bfSize = file.bfOffBits + stride * image.height;
    BITMAPINFOHEADER info{}; info.biSize = sizeof(info); info.biWidth = image.width; info.biHeight = -LONG(image.height);
    info.biPlanes = 1; info.biBitCount = 24; info.biCompression = BI_RGB; info.biSizeImage = stride * image.height;
    std::ofstream stream(path, std::ios::binary); stream.write(reinterpret_cast<char*>(&file), sizeof(file)); stream.write(reinterpret_cast<char*>(&info), sizeof(info));
    std::vector<unsigned char> row(stride);
    auto byte = [](float value) { return static_cast<unsigned char>(std::round(std::clamp(value, 0.0f, 1.0f) * 255)); };
    for (unsigned y = 0; y < image.height; ++y) {
        for (unsigned x = 0; x < image.width; ++x) { const auto& p = image.pixels[size_t(y) * image.width + x]; row[x * 3] = byte(p.b); row[x * 3 + 1] = byte(p.g); row[x * 3 + 2] = byte(p.r); }
        stream.write(reinterpret_cast<char*>(row.data()), row.size());
    }
}

int wmain(int argc, wchar_t** argv) {
    try {
        if (argc != 3) throw std::runtime_error("Usage: gpu_validation.exe shader.hlsl output-directory");
        const fs::path outputDir(argv[2]); fs::create_directories(outputDir);
        Gpu gpu(argv[1]); std::cout << "Hardware adapter: " << gpu.adapterName << '\n';
        std::vector<TestResult> tests;
        auto test = [&](std::string name, double value, double tolerance, bool atLeast = false) {
            const bool passed = std::isfinite(value) && (atLeast ? value >= tolerance : value <= tolerance);
            tests.push_back({name, value, tolerance, passed, atLeast});
            std::cout << (passed ? "PASS " : "FAIL ") << name << " value=" << value << " limit=" << tolerance << '\n';
        };
        for (bool gamma : {false, true}) {
            const std::string mode = gamma ? "gamma" : "linear";
            unsigned flatIndex = 0;
            for (auto color : {Pixel{0, 0, 0, 0}, Pixel{0.18f, 0.4f, 0.72f, 0.37f}, Pixel{1, 1, 1, 1}}) {
                const std::string colorName = std::array<std::string, 3>{"black", "flat RGB", "white"}[flatIndex++];
                auto result = gpu.render(Image(17, 13, color), 43, 31, true, gamma);
                test(mode + " " + colorName + " finite", Nonfinite(result), 0);
                test(mode + " " + colorName + " preservation", Difference(result, Image(43, 31, color), true), 2e-5);
            }
            auto tiny = gpu.render(Image(1, 1, {0.2f, 0.4f, 0.6f, 0.5f}), 9, 7, true, gamma);
            test(mode + " one texel finite", Nonfinite(tiny), 0);
            test(mode + " one texel preservation", Difference(tiny, Image(9, 7, {0.2f, 0.4f, 0.6f, 0.5f}), true), 2e-5);
            Image atlas(32, 16, {1, 0, 0, 0.25f});
            for (unsigned y = 0; y < 16; ++y) for (unsigned x = 16; x < 32; ++x) atlas.at(x, y) = {0, 0, 1, 0.75f};
            auto left = gpu.render(atlas, 64, 48, true, gamma, {0, 0, 0.5f, 1});
            auto right = gpu.render(atlas, 64, 48, true, gamma, {0.5f, 0, 1, 1});
            test(mode + " atlas left eye isolation", Difference(left, Image(64, 48, {1, 0, 0, 0.25f}), true), 2e-5);
            test(mode + " atlas right eye isolation", Difference(right, Image(64, 48, {0, 0, 1, 0.75f}), true), 2e-5);
            const auto source = Pattern(96, 64);
            const auto easu = gpu.render(source, 192, 128, true, gamma);
            const auto bilinear = gpu.render(source, 192, 128, false, gamma);
            test(mode + " edge finite", Nonfinite(easu), 0);
            test(mode + " edge no overshoot", OutOfRange(easu, 0.05f, 0.95f), 2e-5);
            test(mode + " edge differs from bilinear mean", Difference(easu, bilinear, false), 0.0001, true);
            test(mode + " alpha remains bilinear", Difference(easu, bilinear, true, true), 2e-5);
            Bitmap(outputDir / (mode + "-easu.bmp"), easu); Bitmap(outputDir / (mode + "-bilinear.bmp"), bilinear);
            auto minified = gpu.render(source, 48, 32, true, gamma);
            auto reference = gpu.render(source, 48, 32, false, gamma);
            test(mode + " minification finite", Nonfinite(minified), 0);
            test(mode + " minification equals bilinear", Difference(minified, reference, true), 2e-5);
            const auto squareSource = Pattern(64, 64);
            const std::array<float, 4> shear{1.6f, 0.0f, 1.6f, 0.2f};
            const auto sheared = gpu.render(squareSource, 128, 128, true, gamma, {0, 0, 1, 1}, nullptr, 1, shear);
            const auto shearedReference = gpu.render(squareSource, 128, 128, false, gamma, {0, 0, 1, 1}, nullptr, 1, shear);
            test(mode + " sheared minification equals bilinear", Difference(sheared, shearedReference, true), 2e-5);
            if (gamma && gpu.upstreamAvailable) {
                const auto upstream = gpu.render(source, 192, 128, 2, true);
                test("upstream AMD EASU finite", Nonfinite(upstream), 0);
                test("upstream AMD EASU mean absolute difference", Difference(easu, upstream, false), 0.005);
                Bitmap(outputDir / "gamma-upstream-amd.bmp", upstream);
            }
        }
        const auto large = Pattern(1600, 1632);
        std::vector<double> easuTimes, bilinearTimes;
        for (unsigned i = 0; i < 5; ++i) {
            double ms{}; gpu.render(large, 2000, 2040, false, false, {0, 0, 1, 1}, &ms, 8); bilinearTimes.push_back(ms);
            gpu.render(large, 2000, 2040, true, false, {0, 0, 1, 1}, &ms, 8); easuTimes.push_back(ms);
        }
        std::sort(easuTimes.begin(), easuTimes.end()); std::sort(bilinearTimes.begin(), bilinearTimes.end());
        const bool passed = std::all_of(tests.begin(), tests.end(), [](const TestResult& t) { return t.passed; });
        std::ofstream report(outputDir / "result.json"); report << std::setprecision(10);
        report << "{\n  \"adapter\": \"" << gpu.adapterName << "\",\n  \"passed\": " << (passed ? "true" : "false")
            << ",\n  \"upstream_comparison_available\": " << (gpu.upstreamAvailable ? "true" : "false")
            << ",\n  \"scope\": \"D3D11 hardware offscreen helper; not a headset or full compositor benchmark\",\n"
            << "  \"benchmark\": {\"input\": [1600,1632], \"output\": [2000,2040], \"median_easu_ms\": " << easuTimes[2]
            << ", \"median_bilinear_ms\": " << bilinearTimes[2] << ", \"draws_per_sample\": 8, \"samples\": 5},\n  \"tests\": [\n";
        for (size_t i = 0; i < tests.size(); ++i) {
            const auto& t = tests[i]; report << "    {\"name\": \"" << t.name << "\", \"value\": " << t.value << ", \"tolerance\": " << t.tolerance
                << ", \"comparison\": \"" << (t.atLeast ? ">=" : "<=") << "\", \"passed\": " << (t.passed ? "true" : "false") << "}" << (i + 1 == tests.size() ? "\n" : ",\n");
        }
        report << "  ]\n}\n";
        std::cout << "Median GPU helper draw: EASU " << easuTimes[2] << " ms, bilinear " << bilinearTimes[2] << " ms\n";
        return passed ? 0 : 2;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
