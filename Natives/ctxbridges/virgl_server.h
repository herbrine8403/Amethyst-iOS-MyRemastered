//
//  virgl_server.h
//  Amethyst-iOS-MyRemastered
//
//  Task 111：VirGLRenderer(≤26.2) 服务端引导桥对外接口。
//
#ifndef AMETHYST_VIRGL_SERVER_H
#define AMETHYST_VIRGL_SERVER_H

/// vtest server 宿主 dylib（virglrenderer 1.3.0 + libepoxy，Makefile dep_virgl 产物）
#define AME_VIRGL_VTEST_SERVER_LIB "libvtestserver.dylib"

/// virgl guest 库（Mesa 25.0.7 virgl 驱动 + osmesa 前端，Makefile dep_virgl 产物）
#define AME_VIRGL_GUEST_LIB "libOSMesaVirgl.dylib"

#if __cplusplus
extern "C" {
#endif

/// 启动 virgl vtest 服务（幂等）。
/// 设置 VTEST_SOCKET_NAME / GALLIUM_DRIVER=virgl，创建 ANGLE 离屏 ES3 宿主
/// 上下文，并拉起 libvtestserver.dylib 的 vtest_main 服务线程。
/// 返回 0 = 成功；非 0 = 引导失败（调用方记录日志后仍走 osm 桥，错误会在
/// guest 连接阶段显式暴露）。
int ame_virgl_start_server(void);

#if __cplusplus
}
#endif

#endif /* AMETHYST_VIRGL_SERVER_H */
