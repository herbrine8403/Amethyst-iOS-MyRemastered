//
//  gl4es_family_boot.h
//  AngelAuraAmethyst
//
//  ★ [RENDERER-GAP] 新增渲染器（VGPU / GL4ESZL2 / VirGL）的运行时引导接口。
//  ★ [DROP-NGG4ES] 原队列中的 NG-GL4ES 已整支移除。
//  来源：Gsjsjzhznsz/Air-Minecraft-iOS-Launcher（同一项目家族更晚的 fork）。
//  本文件把队友散落在 egl_bridge.m 里的 Task204/211/215 引导逻辑收敛到一处，
//  使宿主文件（egl_bridge.m）只留极少量、且对既有渲染器零影响的调用点。
//
#ifndef AMETHYST_GL4ES_FAMILY_BOOT_H
#define AMETHYST_GL4ES_FAMILY_BOOT_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 是否任一「新增（gap）渲染器」正在被选中（读 AMETHYST_RENDERER）。
bool ame_gap_renderer_selected(void);

/// gl4es 家族（VGPU / GL4ESZL2）的 MakeCurrent 后引导（幂等）。
/// 必须在【真实游戏上下文已 current】之后调用（pojavMakeCurrent 尾部）。
/// - GL4ESZL2：dlopen(RTLD_NOLOAD) + set_getprocaddress(resolver) +
///   initialize_gl4es()（构建带 NO_INIT_CONSTRUCTOR，构造器不跑）。
/// - VGPU：其自带惰性装载器接管，这里只做日志/幂等。
/// 非 gap 渲染器时立即返回（一次 getenv 比较，零副作用）。
void ame_gap_gl4es_family_boot(void);

/// VirGL 服务端引导（幂等）。仅当 AMETHYST_RENDERER == libOSMesaVirgl.dylib 时
/// 转调 ame_virgl_start_server()（启动进程内 vtest server、建 ANGLE 离屏宿主上下文）。
/// 返回 0 = 成功或未选中；非 0 = 引导失败（调用方记录日志后仍走 osm 桥）。
int ame_gap_virgl_boot(void);

#ifdef __cplusplus
}
#endif

#endif /* AMETHYST_GL4ES_FAMILY_BOOT_H */
