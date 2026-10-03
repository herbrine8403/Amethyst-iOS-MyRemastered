// shader_cap_probe.h — ★ [SHADER-CAP] Metal 光影能力:GL 运行时探测 + 诚实扩展上报 + GL 入口映射
//
// 目的(对应 METAL_SHADER_INTERACTION_NOTES.md 第三/五节):
//   1) 对每个候选 GL 入口做运行时探测,把「非空(已实现)/空(未实现)」以 `[SHADER-CAP]` 前缀落日志;
//   2) 把 **运行时验证过确实有实现** 的扩展名补进 glGetString(GL_EXTENSIONS) / glGetStringi;
//   3) 为 SSBO / CUSTOM_IMAGES / SEPARATE SAMPLERS 提供 core↔EXT 别名映射(只在 core 缺失时转发)。
//
// 铁律(与仓库既有纪律一致):「宣布扩展 ≠ 实现扩展」。所有上报都由探测结果驱动,
// 未验证到实现的扩展一律不报 —— 谎报会让上层走未实现路径而崩/黑屏。
// 本模块默认**不改任何现有行为**:探测只读;上报/映射都只在探到真实实现时才介入,
// 且可用环境变量整体关闭:
//   AMETHYST_SHADER_CAP=0        关闭本模块(默认开启,只做探测)
//   AMETHYST_SHADER_CAP_REPORT=0 关闭扩展上报与入口包装(默认开启)
//   AMETHYST_SHADER_CAP_LOG=0    关闭探测逐项日志(默认开启)
//
// 接入方式(见 sdl3_hook.m):
//   ame_shader_cap_setup(ame_shaderCapResolveRaw);   // 提供「从渲染器解析 GL 入口」的回调
//   在 GL 入口解析处调用 ame_shader_cap_resolve_entry(name) —— 非 NULL 即本模块接管。
//   在每帧安全点调用 ame_shader_cap_probe_run_once()(幂等, 需要当前上下文)。

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// 从当前渲染器镜像解析一个 GL 入口(调用方需已做镜像可信校验); 取不到返回 NULL。
typedef void *(*ame_sc_resolve_fn)(const char *name);

// 注入解析器并预解析 glGetString / glGetStringi / glGetIntegerv 的真实实现。幂等。
// resolve 为 NULL 时本模块不做任何事(等价于关闭)。
void ame_shader_cap_setup(ame_sc_resolve_fn resolve);

// 探测一次(幂等)。需要当前 GL 上下文;若此刻没有上下文(glGetString(GL_VERSION)==NULL)
// 则**不置位**, 下次再试 —— 因此可以安全地在每帧安全点无脑调用。
void ame_shader_cap_probe_run_once(void);

// GL 入口解析层用: 返回非 NULL = 本模块接管该入口(包装或别名); 返回 NULL = 调用方走原路径。
void *ame_shader_cap_resolve_entry(const char *name);

#ifdef __cplusplus
}
#endif
