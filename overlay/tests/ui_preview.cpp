// Предпросмотр окна без игры: настоящий ImGui (той же версии, что в ReShade), программная отрисовка в PPM.
// Заодно проверка: проверки ImGui (IM_ASSERT) включены, ошибка в вызовах ImGui остановит программу.
//
//   gfg_ui_preview <ui.json> <out.ppm> <шрифт.ttf> [действия через запятую] [ширина высота]
//   ui.json — ответ GET /api/ui сервиса; действия: open, up, down, left, right, confirm, back, hide.
#include <imgui.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "model.hpp"
#include "nav.hpp"
#include "ui.hpp"

namespace {

struct Canvas {
    int w, h;
    std::vector<float> rgb;  // 0..1
    Canvas(int w_, int h_) : w(w_), h(h_), rgb(size_t(w_) * h_ * 3) {
        // Фон «как в игре»: тёмный градиент.
        for (int y = 0; y < h; ++y)
            for (int x = 0; x < w; ++x) {
                float* p = &rgb[(size_t(y) * w + x) * 3];
                p[0] = 0.10f + 0.10f * x / w;
                p[1] = 0.13f + 0.06f * y / h;
                p[2] = 0.12f + 0.04f * x / w;
            }
    }
    void save(const char* path) const {
        std::ofstream f(path, std::ios::binary);
        f << "P6\n" << w << " " << h << "\n255\n";
        for (float v : rgb) f.put(char(std::clamp(int(std::lround(v * 255.0f)), 0, 255)));
    }
};

ImVec4 texel(const ImTextureData* tex, float u, float v) {
    if (!tex) return ImVec4(1, 1, 1, 1);
    const int x = std::clamp(int(u * tex->Width), 0, tex->Width - 1);
    const int y = std::clamp(int(v * tex->Height), 0, tex->Height - 1);
    const unsigned char* p = static_cast<const unsigned char*>(const_cast<ImTextureData*>(tex)->GetPixelsAt(x, y));
    if (tex->Format == ImTextureFormat_Alpha8) return ImVec4(1, 1, 1, p[0] / 255.0f);
    return ImVec4(p[0] / 255.0f, p[1] / 255.0f, p[2] / 255.0f, p[3] / 255.0f);
}

ImVec4 color(ImU32 c) {
    return ImVec4((c & 0xFF) / 255.0f, ((c >> 8) & 0xFF) / 255.0f, ((c >> 16) & 0xFF) / 255.0f, ((c >> 24) & 0xFF) / 255.0f);
}

void rasterize(Canvas& cv, const ImDrawData* dd) {
    for (const ImDrawList* list : dd->CmdLists) {
        for (const ImDrawCmd& cmd : list->CmdBuffer) {
            if (cmd.UserCallback) continue;
            const auto* tex = reinterpret_cast<const ImTextureData*>(cmd.GetTexID());
            const int cx0 = std::max(0, int(cmd.ClipRect.x)), cy0 = std::max(0, int(cmd.ClipRect.y));
            const int cx1 = std::min(cv.w, int(cmd.ClipRect.z)), cy1 = std::min(cv.h, int(cmd.ClipRect.w));
            for (unsigned i = 0; i + 2 < cmd.ElemCount; i += 3) {
                const ImDrawVert* v[3];
                for (int k = 0; k < 3; ++k) v[k] = &list->VtxBuffer[cmd.VtxOffset + list->IdxBuffer[cmd.IdxOffset + i + k]];
                const float area = (v[1]->pos.x - v[0]->pos.x) * (v[2]->pos.y - v[0]->pos.y) -
                                   (v[2]->pos.x - v[0]->pos.x) * (v[1]->pos.y - v[0]->pos.y);
                if (std::fabs(area) < 1e-6f) continue;
                const int x0 = std::max(cx0, int(std::floor(std::min({v[0]->pos.x, v[1]->pos.x, v[2]->pos.x}))));
                const int x1 = std::min(cx1, int(std::ceil(std::max({v[0]->pos.x, v[1]->pos.x, v[2]->pos.x}))));
                const int y0 = std::max(cy0, int(std::floor(std::min({v[0]->pos.y, v[1]->pos.y, v[2]->pos.y}))));
                const int y1 = std::min(cy1, int(std::ceil(std::max({v[0]->pos.y, v[1]->pos.y, v[2]->pos.y}))));
                const ImVec4 c0 = color(v[0]->col), c1 = color(v[1]->col), c2 = color(v[2]->col);
                for (int y = y0; y < y1; ++y)
                    for (int x = x0; x < x1; ++x) {
                        const float px = x + 0.5f, py = y + 0.5f;
                        float w0 = ((v[1]->pos.x - px) * (v[2]->pos.y - py) - (v[2]->pos.x - px) * (v[1]->pos.y - py)) / area;
                        float w1 = ((v[2]->pos.x - px) * (v[0]->pos.y - py) - (v[0]->pos.x - px) * (v[2]->pos.y - py)) / area;
                        float w2 = 1.0f - w0 - w1;
                        if (w0 < -1e-4f || w1 < -1e-4f || w2 < -1e-4f) continue;
                        const float u = w0 * v[0]->uv.x + w1 * v[1]->uv.x + w2 * v[2]->uv.x;
                        const float t = w0 * v[0]->uv.y + w1 * v[1]->uv.y + w2 * v[2]->uv.y;
                        const ImVec4 tx = texel(tex, u, t);
                        const float r = (w0 * c0.x + w1 * c1.x + w2 * c2.x) * tx.x;
                        const float g = (w0 * c0.y + w1 * c1.y + w2 * c2.y) * tx.y;
                        const float b = (w0 * c0.z + w1 * c1.z + w2 * c2.z) * tx.z;
                        const float a = (w0 * c0.w + w1 * c1.w + w2 * c2.w) * tx.w;
                        float* p = &cv.rgb[(size_t(y) * cv.w + x) * 3];
                        p[0] = p[0] * (1 - a) + r * a;
                        p[1] = p[1] * (1 - a) + g * a;
                        p[2] = p[2] * (1 - a) + b * a;
                    }
            }
        }
    }
}

// «Загрузка» текстур в программный рендер: пиксели остаются в ImTextureData, id — указатель на неё.
void update_textures(ImDrawData* dd) {
    if (!dd->Textures) return;
    for (ImTextureData* tex : *dd->Textures) {
        if (tex->Status == ImTextureStatus_WantCreate || tex->Status == ImTextureStatus_WantUpdates) {
            tex->SetTexID(reinterpret_cast<ImTextureID>(tex));
            tex->SetStatus(ImTextureStatus_OK);
        } else if (tex->Status == ImTextureStatus_WantDestroy) {
            tex->SetTexID(ImTextureID_Invalid);
            tex->SetStatus(ImTextureStatus_Destroyed);
        }
    }
}

gfg::Action action_of(const std::string& s) {
    if (s == "open") return gfg::Action::Toggle;
    if (s == "up") return gfg::Action::Up;
    if (s == "down") return gfg::Action::Down;
    if (s == "left") return gfg::Action::TabPrev;
    if (s == "right") return gfg::Action::TabNext;
    if (s == "confirm") return gfg::Action::Confirm;
    if (s == "back") return gfg::Action::Back;
    if (s == "hide") return gfg::Action::Hide;
    std::fprintf(stderr, "unknown action %s\n", s.c_str());
    std::exit(2);
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 4) {
        std::fprintf(stderr, "usage: gfg_ui_preview <ui.json> <out.ppm> <font.ttf> [actions] [w h]\n");
        return 2;
    }
    std::ifstream in(argv[1]);
    std::stringstream ss;
    ss << in.rdbuf();
    gfg::Message msg = gfg::parse_message("{\"type\":\"ui\",\"ui\":" + ss.str() + "}");
    if (msg.type != gfg::MessageType::Ui) {
        std::fprintf(stderr, "bad ui.json: %s\n", msg.error.c_str());
        return 1;
    }
    const gfg::UiModel& model = msg.ui;
    const int w = argc > 6 ? std::atoi(argv[5]) : 1600, h = argc > 6 ? std::atoi(argv[6]) : 900;

    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.DisplaySize = ImVec2(float(w), float(h));
    io.BackendFlags |= ImGuiBackendFlags_RendererHasTextures;
    io.IniFilename = nullptr;
    if (!io.Fonts->AddFontFromFileTTF(argv[3], 18.0f)) {
        std::fprintf(stderr, "font not loaded: %s\n", argv[3]);
        return 1;
    }

    gfg::Nav nav;
    bool scroll = false;
    std::vector<std::string> actions;
    if (argc > 4) {
        std::stringstream as(argv[4]);
        for (std::string a; std::getline(as, a, ',');)
            if (!a.empty()) actions.push_back(a);
    }
    if (actions.empty()) actions.push_back("open");

    int sent = 0;
    // Несколько кадров на каждое действие: ImGui раскладывает окно не с первого кадра.
    for (size_t step = 0; step <= actions.size(); ++step) {
        if (step < actions.size()) {
            if (auto cmd = gfg::apply(nav, action_of(actions[step]), model)) {
                std::printf("command: %s\n", cmd->c_str());
                ++sent;
            }
            scroll = true;
        }
        for (int f = 0; f < 3; ++f) {
            io.DeltaTime = 1.0f / 60.0f;
            ImGui::NewFrame();
            if (nav.open) {
                gfg::UiView view{.model = model, .nav = nav};
                view.connected = true;
                view.scroll_to_selected = &scroll;
                view.send = [&](const std::string& c) { std::printf("button: %s\n", c.c_str()); };
                gfg::draw_help_window(view);
            }
            ImGui::Render();
            update_textures(ImGui::GetDrawData());
        }
    }
    Canvas cv(w, h);
    rasterize(cv, ImGui::GetDrawData());
    cv.save(argv[2]);
    std::printf("saved %s (%d commands)\n", argv[2], sent);
    ImGui::DestroyContext();
    return 0;
}
