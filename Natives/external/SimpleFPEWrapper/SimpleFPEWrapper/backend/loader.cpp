// SimpleFPEWrapper - SimpleFPEWrapper/backend/loader.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#include "loader.h"
#include <dlfcn.h>
#include <cstring>
#include <vector>

namespace SFPEW::Utils::BackendLoader {
    static void* OpenLib(const std::vector<std::string>& names) {
#if defined(__APPLE__)
        // iOS: 没有 /usr/lib 一类统一的库搜索路径约定。SFPEW_EGL 传入的是
        // "@rpath/libXXX.dylib" 或绝对路径，直接 dlopen 即可（上游的
        // Linux 前缀列表在 Apple 上不存在，原先整个函数恒返回 nullptr，
        // 导致 InitBackend() 失败、wrapper 静默停用）。
        for (const auto& name : names) {
            if (name.empty()) continue;
            void* lib = dlopen(name.c_str(), RTLD_LOCAL | RTLD_NOW);
            if (lib != nullptr) return lib;
        }
        return nullptr;
#elif !defined(__WIN32) && !defined(_WIN32)
        static const std::string LibPathPrefixes[] = {
            "/opt/vc/lib/", "/usr/local/lib/", "/usr/lib/", "/usr/lib/x86_64-linux-gnu/",
            "" // We should put this to the end of the list to avoid breaking `LD_LIBRARY_PATH` usage
        };

        void* lib = nullptr;

        int flags = RTLD_LOCAL | RTLD_NOW;
        for (const auto& prefix : LibPathPrefixes) {
            for (const auto& name : names) {
                std::string path_name = prefix + name;
                if ((lib = dlopen(path_name.c_str(), flags))) {
                    return lib;
                }
            }
        }
#endif
        return nullptr;
    }

    inline void* ProcAddress(void* lib, const char* name) {
#if !defined(__WIN32) && !defined(_WIN32)
        // Apple 同样有 dlsym；上游把 Apple 一并排除会让全部 EGL 入口点
        // 解析成 nullptr（417 个指针全空 = wrapper 完全不可用）。
        return dlsym(lib, name);
#else
        return nullptr;
#endif
    }

    bool AcquireBackendGLFunctions(External::BackendGLFunctionsTable& funcs,
                                   External::EGL::eglGetProcAddress_PTR procAddress) {
        if (!procAddress) {
            return false;
        }

#define INIT_BACKENDGL_FUNC(name)                                                                                      \
    do {                                                                                                               \
        funcs.name = (External::BackendGL::name##_PTR)procAddress(#name);                                              \
    } while (0);

        {
            INIT_BACKENDGL_FUNC(glActiveTexture)
            INIT_BACKENDGL_FUNC(glAttachShader)
            INIT_BACKENDGL_FUNC(glBindAttribLocation)
            INIT_BACKENDGL_FUNC(glBindBuffer)
            INIT_BACKENDGL_FUNC(glBindFramebuffer)
            INIT_BACKENDGL_FUNC(glBindRenderbuffer)
            INIT_BACKENDGL_FUNC(glBindTexture)
            INIT_BACKENDGL_FUNC(glBlendColor)
            INIT_BACKENDGL_FUNC(glBlendEquation)
            INIT_BACKENDGL_FUNC(glBlendEquationSeparate)
            INIT_BACKENDGL_FUNC(glBlendFunc)
            INIT_BACKENDGL_FUNC(glBlendFuncSeparate)
            INIT_BACKENDGL_FUNC(glBufferData)
            INIT_BACKENDGL_FUNC(glBufferSubData)
            INIT_BACKENDGL_FUNC(glCheckFramebufferStatus)
            INIT_BACKENDGL_FUNC(glClear)
            INIT_BACKENDGL_FUNC(glClearColor)
            INIT_BACKENDGL_FUNC(glClearDepthf)
            INIT_BACKENDGL_FUNC(glClearStencil)
            INIT_BACKENDGL_FUNC(glColorMask)
            INIT_BACKENDGL_FUNC(glCompileShader)
            INIT_BACKENDGL_FUNC(glCompressedTexImage2D)
            INIT_BACKENDGL_FUNC(glCompressedTexSubImage2D)
            //    INIT_BACKENDGL_FUNC(glCopyTexImage1D)
            INIT_BACKENDGL_FUNC(glCopyTexImage2D)
            INIT_BACKENDGL_FUNC(glCopyTexSubImage2D)
            INIT_BACKENDGL_FUNC(glCreateProgram)
            INIT_BACKENDGL_FUNC(glCreateShader)
            INIT_BACKENDGL_FUNC(glCullFace)
            INIT_BACKENDGL_FUNC(glDeleteBuffers)
            INIT_BACKENDGL_FUNC(glDeleteFramebuffers)
            INIT_BACKENDGL_FUNC(glDeleteProgram)
            INIT_BACKENDGL_FUNC(glDeleteRenderbuffers)
            INIT_BACKENDGL_FUNC(glDeleteShader)
            INIT_BACKENDGL_FUNC(glDeleteTextures)
            INIT_BACKENDGL_FUNC(glDepthFunc)
            INIT_BACKENDGL_FUNC(glDepthMask)
            INIT_BACKENDGL_FUNC(glDepthRangef)
            INIT_BACKENDGL_FUNC(glDetachShader)
            INIT_BACKENDGL_FUNC(glDisable)
            INIT_BACKENDGL_FUNC(glDisableVertexAttribArray)
            INIT_BACKENDGL_FUNC(glDrawArrays)
            INIT_BACKENDGL_FUNC(glDrawElements)
            INIT_BACKENDGL_FUNC(glEnable)
            INIT_BACKENDGL_FUNC(glEnableVertexAttribArray)
            INIT_BACKENDGL_FUNC(glFinish)
            INIT_BACKENDGL_FUNC(glFlush)
            INIT_BACKENDGL_FUNC(glFramebufferRenderbuffer)
            INIT_BACKENDGL_FUNC(glFramebufferTexture2D)
            INIT_BACKENDGL_FUNC(glFrontFace)
            INIT_BACKENDGL_FUNC(glGenBuffers)
            INIT_BACKENDGL_FUNC(glGenerateMipmap)
            INIT_BACKENDGL_FUNC(glGenFramebuffers)
            INIT_BACKENDGL_FUNC(glGenRenderbuffers)
            INIT_BACKENDGL_FUNC(glGenTextures)
            INIT_BACKENDGL_FUNC(glGetActiveAttrib)
            INIT_BACKENDGL_FUNC(glGetActiveUniform)
            INIT_BACKENDGL_FUNC(glGetAttachedShaders)
            INIT_BACKENDGL_FUNC(glGetAttribLocation)
            INIT_BACKENDGL_FUNC(glGetBooleanv)
            INIT_BACKENDGL_FUNC(glGetBufferParameteriv)
            INIT_BACKENDGL_FUNC(glGetCompressedTexImage)
            INIT_BACKENDGL_FUNC(glGetTexImage)
            INIT_BACKENDGL_FUNC(glGetError)
            INIT_BACKENDGL_FUNC(glGetString)
            INIT_BACKENDGL_FUNC(glGetStringi)
            INIT_BACKENDGL_FUNC(glGetFloatv)
            INIT_BACKENDGL_FUNC(glGetFramebufferAttachmentParameteriv)
            INIT_BACKENDGL_FUNC(glGetIntegerv)
            INIT_BACKENDGL_FUNC(glGetProgramiv)
            INIT_BACKENDGL_FUNC(glGetProgramInfoLog)
            INIT_BACKENDGL_FUNC(glGetRenderbufferParameteriv)
            INIT_BACKENDGL_FUNC(glGetShaderiv)
            INIT_BACKENDGL_FUNC(glGetShaderInfoLog)
            INIT_BACKENDGL_FUNC(glGetShaderPrecisionFormat)
            INIT_BACKENDGL_FUNC(glGetShaderSource)
            INIT_BACKENDGL_FUNC(glGetTexParameterfv)
            INIT_BACKENDGL_FUNC(glGetTexParameteriv)
            INIT_BACKENDGL_FUNC(glGetUniformfv)
            INIT_BACKENDGL_FUNC(glGetUniformiv)
            INIT_BACKENDGL_FUNC(glGetUniformLocation)
            INIT_BACKENDGL_FUNC(glGetVertexAttribfv)
            INIT_BACKENDGL_FUNC(glGetVertexAttribiv)
            INIT_BACKENDGL_FUNC(glGetVertexAttribPointerv)
            INIT_BACKENDGL_FUNC(glHint)
            INIT_BACKENDGL_FUNC(glIsBuffer)
            INIT_BACKENDGL_FUNC(glIsEnabled)
            INIT_BACKENDGL_FUNC(glIsFramebuffer)
            INIT_BACKENDGL_FUNC(glIsProgram)
            INIT_BACKENDGL_FUNC(glIsRenderbuffer)
            INIT_BACKENDGL_FUNC(glIsShader)
            INIT_BACKENDGL_FUNC(glIsTexture)
            INIT_BACKENDGL_FUNC(glLineWidth)
            INIT_BACKENDGL_FUNC(glLinkProgram)
            INIT_BACKENDGL_FUNC(glPixelStorei)
            INIT_BACKENDGL_FUNC(glPolygonOffset)
            INIT_BACKENDGL_FUNC(glReadPixels)
            INIT_BACKENDGL_FUNC(glReleaseShaderCompiler)
            INIT_BACKENDGL_FUNC(glRenderbufferStorage)
            INIT_BACKENDGL_FUNC(glSampleCoverage)
            INIT_BACKENDGL_FUNC(glScissor)
            INIT_BACKENDGL_FUNC(glShaderBinary)
            INIT_BACKENDGL_FUNC(glShaderSource)
            INIT_BACKENDGL_FUNC(glStencilFunc)
            INIT_BACKENDGL_FUNC(glStencilFuncSeparate)
            INIT_BACKENDGL_FUNC(glStencilMask)
            INIT_BACKENDGL_FUNC(glStencilMaskSeparate)
            INIT_BACKENDGL_FUNC(glStencilOp)
            INIT_BACKENDGL_FUNC(glStencilOpSeparate)
            //    INIT_BACKENDGL_FUNC(glTexImage1D)
            INIT_BACKENDGL_FUNC(glTexImage2D)
            //    INIT_BACKENDGL_FUNC(glTexStorage1D)
            INIT_BACKENDGL_FUNC(glTexParameterf)
            INIT_BACKENDGL_FUNC(glTexParameterfv)
            INIT_BACKENDGL_FUNC(glTexParameteri)
            INIT_BACKENDGL_FUNC(glTexParameteriv)
            INIT_BACKENDGL_FUNC(glTexSubImage2D)
            INIT_BACKENDGL_FUNC(glUniform1f)
            INIT_BACKENDGL_FUNC(glUniform1fv)
            INIT_BACKENDGL_FUNC(glUniform1i)
            INIT_BACKENDGL_FUNC(glUniform1iv)
            INIT_BACKENDGL_FUNC(glUniform2f)
            INIT_BACKENDGL_FUNC(glUniform2fv)
            INIT_BACKENDGL_FUNC(glUniform2i)
            INIT_BACKENDGL_FUNC(glUniform2iv)
            INIT_BACKENDGL_FUNC(glUniform3f)
            INIT_BACKENDGL_FUNC(glUniform3fv)
            INIT_BACKENDGL_FUNC(glUniform3i)
            INIT_BACKENDGL_FUNC(glUniform3iv)
            INIT_BACKENDGL_FUNC(glUniform4f)
            INIT_BACKENDGL_FUNC(glUniform4fv)
            INIT_BACKENDGL_FUNC(glUniform4i)
            INIT_BACKENDGL_FUNC(glUniform4iv)
            INIT_BACKENDGL_FUNC(glUniformMatrix2fv)
            INIT_BACKENDGL_FUNC(glUniformMatrix3fv)
            INIT_BACKENDGL_FUNC(glUniformMatrix4fv)
            INIT_BACKENDGL_FUNC(glUseProgram)
            INIT_BACKENDGL_FUNC(glValidateProgram)
            INIT_BACKENDGL_FUNC(glVertexAttrib1f)
            INIT_BACKENDGL_FUNC(glVertexAttrib1fv)
            INIT_BACKENDGL_FUNC(glVertexAttrib2f)
            INIT_BACKENDGL_FUNC(glVertexAttrib2fv)
            INIT_BACKENDGL_FUNC(glVertexAttrib3f)
            INIT_BACKENDGL_FUNC(glVertexAttrib3fv)
            INIT_BACKENDGL_FUNC(glVertexAttrib4f)
            INIT_BACKENDGL_FUNC(glVertexAttrib4fv)
            INIT_BACKENDGL_FUNC(glVertexAttribPointer)
            INIT_BACKENDGL_FUNC(glViewport)
            INIT_BACKENDGL_FUNC(glReadBuffer)
            INIT_BACKENDGL_FUNC(glDrawRangeElements)
            INIT_BACKENDGL_FUNC(glTexImage3D)
            INIT_BACKENDGL_FUNC(glTexSubImage3D)
            INIT_BACKENDGL_FUNC(glCopyTexSubImage3D)
            INIT_BACKENDGL_FUNC(glCompressedTexImage3D)
            INIT_BACKENDGL_FUNC(glCompressedTexSubImage3D)
            INIT_BACKENDGL_FUNC(glGenQueries)
            INIT_BACKENDGL_FUNC(glDeleteQueries)
            INIT_BACKENDGL_FUNC(glIsQuery)
            INIT_BACKENDGL_FUNC(glBeginQuery)
            INIT_BACKENDGL_FUNC(glEndQuery)
            INIT_BACKENDGL_FUNC(glGetQueryiv)
            INIT_BACKENDGL_FUNC(glGetQueryObjectuiv)
            INIT_BACKENDGL_FUNC(glUnmapBuffer)
            INIT_BACKENDGL_FUNC(glGetBufferPointerv)
            INIT_BACKENDGL_FUNC(glDrawBuffers)
            INIT_BACKENDGL_FUNC(glUniformMatrix2x3fv)
            INIT_BACKENDGL_FUNC(glUniformMatrix3x2fv)
            INIT_BACKENDGL_FUNC(glUniformMatrix2x4fv)
            INIT_BACKENDGL_FUNC(glUniformMatrix4x2fv)
            INIT_BACKENDGL_FUNC(glUniformMatrix3x4fv)
            INIT_BACKENDGL_FUNC(glUniformMatrix4x3fv)
            INIT_BACKENDGL_FUNC(glBlitFramebuffer)
            INIT_BACKENDGL_FUNC(glRenderbufferStorageMultisample)
            INIT_BACKENDGL_FUNC(glFramebufferTextureLayer)
            INIT_BACKENDGL_FUNC(glFlushMappedBufferRange)
            INIT_BACKENDGL_FUNC(glBindVertexArray)
            INIT_BACKENDGL_FUNC(glDeleteVertexArrays)
            INIT_BACKENDGL_FUNC(glGenVertexArrays)
            INIT_BACKENDGL_FUNC(glIsVertexArray)
            INIT_BACKENDGL_FUNC(glGetIntegeri_v)
            INIT_BACKENDGL_FUNC(glBeginTransformFeedback)
            INIT_BACKENDGL_FUNC(glEndTransformFeedback)
            INIT_BACKENDGL_FUNC(glBindBufferRange)
            INIT_BACKENDGL_FUNC(glBindBufferBase)
            INIT_BACKENDGL_FUNC(glTransformFeedbackVaryings)
            INIT_BACKENDGL_FUNC(glGetTransformFeedbackVarying)
            INIT_BACKENDGL_FUNC(glVertexAttribIPointer)
            INIT_BACKENDGL_FUNC(glGetVertexAttribIiv)
            INIT_BACKENDGL_FUNC(glGetVertexAttribIuiv)
            INIT_BACKENDGL_FUNC(glVertexAttribI4i)
            INIT_BACKENDGL_FUNC(glVertexAttribI4ui)
            INIT_BACKENDGL_FUNC(glVertexAttribI4iv)
            INIT_BACKENDGL_FUNC(glVertexAttribI4uiv)
            INIT_BACKENDGL_FUNC(glGetUniformuiv)
            INIT_BACKENDGL_FUNC(glGetFragDataLocation)
            INIT_BACKENDGL_FUNC(glUniform1ui)
            INIT_BACKENDGL_FUNC(glUniform2ui)
            INIT_BACKENDGL_FUNC(glUniform3ui)
            INIT_BACKENDGL_FUNC(glUniform4ui)
            INIT_BACKENDGL_FUNC(glUniform1uiv)
            INIT_BACKENDGL_FUNC(glUniform2uiv)
            INIT_BACKENDGL_FUNC(glUniform3uiv)
            INIT_BACKENDGL_FUNC(glUniform4uiv)
            INIT_BACKENDGL_FUNC(glClearBufferiv)
            INIT_BACKENDGL_FUNC(glClearBufferuiv)
            INIT_BACKENDGL_FUNC(glClearBufferfv)
            INIT_BACKENDGL_FUNC(glClearBufferfi)
            INIT_BACKENDGL_FUNC(glCopyBufferSubData)
            INIT_BACKENDGL_FUNC(glGetUniformIndices)
            INIT_BACKENDGL_FUNC(glGetActiveUniformsiv)
            INIT_BACKENDGL_FUNC(glGetUniformBlockIndex)
            INIT_BACKENDGL_FUNC(glGetActiveUniformBlockiv)
            INIT_BACKENDGL_FUNC(glGetActiveUniformBlockName)
            INIT_BACKENDGL_FUNC(glUniformBlockBinding)
            INIT_BACKENDGL_FUNC(glDrawArraysInstanced)
            INIT_BACKENDGL_FUNC(glDrawElementsInstanced)
            INIT_BACKENDGL_FUNC(glMultiDrawArrays)
            INIT_BACKENDGL_FUNC(glMultiDrawElements)
            INIT_BACKENDGL_FUNC(glMultiDrawArraysEXT)
            INIT_BACKENDGL_FUNC(glMultiDrawElementsEXT)
            INIT_BACKENDGL_FUNC(glMultiDrawElementsBaseVertex)
            INIT_BACKENDGL_FUNC(glFenceSync)
            INIT_BACKENDGL_FUNC(glIsSync)
            INIT_BACKENDGL_FUNC(glDeleteSync)
            INIT_BACKENDGL_FUNC(glClientWaitSync)
            INIT_BACKENDGL_FUNC(glWaitSync)
            INIT_BACKENDGL_FUNC(glGetInteger64v)
            INIT_BACKENDGL_FUNC(glGetSynciv)
            INIT_BACKENDGL_FUNC(glGetInteger64i_v)
            INIT_BACKENDGL_FUNC(glGetBufferParameteri64v)
            INIT_BACKENDGL_FUNC(glGenSamplers)
            INIT_BACKENDGL_FUNC(glDeleteSamplers)
            INIT_BACKENDGL_FUNC(glIsSampler)
            INIT_BACKENDGL_FUNC(glBindSampler)
            INIT_BACKENDGL_FUNC(glSamplerParameteri)
            INIT_BACKENDGL_FUNC(glSamplerParameteriv)
            INIT_BACKENDGL_FUNC(glSamplerParameterf)
            INIT_BACKENDGL_FUNC(glSamplerParameterfv)
            INIT_BACKENDGL_FUNC(glGetSamplerParameteriv)
            INIT_BACKENDGL_FUNC(glGetSamplerParameterfv)
            INIT_BACKENDGL_FUNC(glVertexAttribDivisor)
            INIT_BACKENDGL_FUNC(glBindTransformFeedback)
            INIT_BACKENDGL_FUNC(glDeleteTransformFeedbacks)
            INIT_BACKENDGL_FUNC(glGenTransformFeedbacks)
            INIT_BACKENDGL_FUNC(glIsTransformFeedback)
            INIT_BACKENDGL_FUNC(glPauseTransformFeedback)
            INIT_BACKENDGL_FUNC(glResumeTransformFeedback)
            INIT_BACKENDGL_FUNC(glGetProgramBinary)
            INIT_BACKENDGL_FUNC(glProgramBinary)
            INIT_BACKENDGL_FUNC(glProgramParameteri)
            INIT_BACKENDGL_FUNC(glInvalidateFramebuffer)
            INIT_BACKENDGL_FUNC(glInvalidateSubFramebuffer)
            INIT_BACKENDGL_FUNC(glTexStorage2D)
            INIT_BACKENDGL_FUNC(glTexStorage3D)
            INIT_BACKENDGL_FUNC(glGetInternalformativ)
            INIT_BACKENDGL_FUNC(glDispatchCompute)
            INIT_BACKENDGL_FUNC(glDispatchComputeIndirect)
            INIT_BACKENDGL_FUNC(glDrawArraysIndirect)
            INIT_BACKENDGL_FUNC(glDrawElementsIndirect)
            INIT_BACKENDGL_FUNC(glFramebufferParameteri)
            INIT_BACKENDGL_FUNC(glGetFramebufferParameteriv)
            INIT_BACKENDGL_FUNC(glGetProgramInterfaceiv)
            INIT_BACKENDGL_FUNC(glGetProgramResourceIndex)
            INIT_BACKENDGL_FUNC(glGetProgramResourceName)
            INIT_BACKENDGL_FUNC(glGetProgramResourceiv)
            INIT_BACKENDGL_FUNC(glGetProgramResourceLocation)
            INIT_BACKENDGL_FUNC(glUseProgramStages)
            INIT_BACKENDGL_FUNC(glActiveShaderProgram)
            INIT_BACKENDGL_FUNC(glCreateShaderProgramv)
            INIT_BACKENDGL_FUNC(glBindProgramPipeline)
            INIT_BACKENDGL_FUNC(glDeleteProgramPipelines)
            INIT_BACKENDGL_FUNC(glGenProgramPipelines)
            INIT_BACKENDGL_FUNC(glIsProgramPipeline)
            INIT_BACKENDGL_FUNC(glGetProgramPipelineiv)
            INIT_BACKENDGL_FUNC(glProgramUniform1i)
            INIT_BACKENDGL_FUNC(glProgramUniform2i)
            INIT_BACKENDGL_FUNC(glProgramUniform3i)
            INIT_BACKENDGL_FUNC(glProgramUniform4i)
            INIT_BACKENDGL_FUNC(glProgramUniform1ui)
            INIT_BACKENDGL_FUNC(glProgramUniform2ui)
            INIT_BACKENDGL_FUNC(glProgramUniform3ui)
            INIT_BACKENDGL_FUNC(glProgramUniform4ui)
            INIT_BACKENDGL_FUNC(glProgramUniform1f)
            INIT_BACKENDGL_FUNC(glProgramUniform2f)
            INIT_BACKENDGL_FUNC(glProgramUniform3f)
            INIT_BACKENDGL_FUNC(glProgramUniform4f)
            INIT_BACKENDGL_FUNC(glProgramUniform1iv)
            INIT_BACKENDGL_FUNC(glProgramUniform2iv)
            INIT_BACKENDGL_FUNC(glProgramUniform3iv)
            INIT_BACKENDGL_FUNC(glProgramUniform4iv)
            INIT_BACKENDGL_FUNC(glProgramUniform1uiv)
            INIT_BACKENDGL_FUNC(glProgramUniform2uiv)
            INIT_BACKENDGL_FUNC(glProgramUniform3uiv)
            INIT_BACKENDGL_FUNC(glProgramUniform4uiv)
            INIT_BACKENDGL_FUNC(glProgramUniform1fv)
            INIT_BACKENDGL_FUNC(glProgramUniform2fv)
            INIT_BACKENDGL_FUNC(glProgramUniform3fv)
            INIT_BACKENDGL_FUNC(glProgramUniform4fv)
            INIT_BACKENDGL_FUNC(glProgramUniformMatrix2fv)
            INIT_BACKENDGL_FUNC(glProgramUniformMatrix3fv)
            INIT_BACKENDGL_FUNC(glProgramUniformMatrix4fv)
            INIT_BACKENDGL_FUNC(glProgramUniformMatrix2x3fv)
            INIT_BACKENDGL_FUNC(glProgramUniformMatrix3x2fv)
            INIT_BACKENDGL_FUNC(glProgramUniformMatrix2x4fv)
            INIT_BACKENDGL_FUNC(glProgramUniformMatrix4x2fv)
            INIT_BACKENDGL_FUNC(glProgramUniformMatrix3x4fv)
            INIT_BACKENDGL_FUNC(glProgramUniformMatrix4x3fv)
            INIT_BACKENDGL_FUNC(glValidateProgramPipeline)
            INIT_BACKENDGL_FUNC(glGetProgramPipelineInfoLog)
            INIT_BACKENDGL_FUNC(glBindImageTexture)
            INIT_BACKENDGL_FUNC(glGetBooleani_v)
            INIT_BACKENDGL_FUNC(glMemoryBarrier)
            INIT_BACKENDGL_FUNC(glMemoryBarrierByRegion)
            INIT_BACKENDGL_FUNC(glTexStorage2DMultisample)
            INIT_BACKENDGL_FUNC(glGetMultisamplefv)
            INIT_BACKENDGL_FUNC(glSampleMaski)
            INIT_BACKENDGL_FUNC(glGetTexLevelParameteriv)
            INIT_BACKENDGL_FUNC(glGetTexLevelParameterfv)
            INIT_BACKENDGL_FUNC(glBindVertexBuffer)
            INIT_BACKENDGL_FUNC(glVertexAttribFormat)
            INIT_BACKENDGL_FUNC(glVertexAttribIFormat)
            INIT_BACKENDGL_FUNC(glVertexAttribBinding)
            INIT_BACKENDGL_FUNC(glVertexBindingDivisor)
            INIT_BACKENDGL_FUNC(glBlendBarrier)
            INIT_BACKENDGL_FUNC(glCopyImageSubData)
            INIT_BACKENDGL_FUNC(glDebugMessageControl)
            INIT_BACKENDGL_FUNC(glDebugMessageInsert)
            INIT_BACKENDGL_FUNC(glDebugMessageCallback)
            INIT_BACKENDGL_FUNC(glGetDebugMessageLog)
            INIT_BACKENDGL_FUNC(glPushDebugGroup)
            INIT_BACKENDGL_FUNC(glPopDebugGroup)
            INIT_BACKENDGL_FUNC(glObjectLabel)
            INIT_BACKENDGL_FUNC(glGetObjectLabel)
            INIT_BACKENDGL_FUNC(glObjectPtrLabel)
            INIT_BACKENDGL_FUNC(glGetObjectPtrLabel)
            INIT_BACKENDGL_FUNC(glGetPointerv)
            INIT_BACKENDGL_FUNC(glEnablei)
            INIT_BACKENDGL_FUNC(glDisablei)
            INIT_BACKENDGL_FUNC(glBlendEquationi)
            INIT_BACKENDGL_FUNC(glBlendEquationSeparatei)
            INIT_BACKENDGL_FUNC(glBlendFunci)
            INIT_BACKENDGL_FUNC(glBlendFuncSeparatei)
            INIT_BACKENDGL_FUNC(glColorMaski)
            INIT_BACKENDGL_FUNC(glIsEnabledi)
            INIT_BACKENDGL_FUNC(glDrawElementsBaseVertex)
            INIT_BACKENDGL_FUNC(glDrawRangeElementsBaseVertex)
            INIT_BACKENDGL_FUNC(glDrawElementsInstancedBaseVertex)
            INIT_BACKENDGL_FUNC(glFramebufferTexture)
            INIT_BACKENDGL_FUNC(glPrimitiveBoundingBox)
            INIT_BACKENDGL_FUNC(glGetGraphicsResetStatus)
            INIT_BACKENDGL_FUNC(glReadnPixels)
            INIT_BACKENDGL_FUNC(glGetnUniformfv)
            INIT_BACKENDGL_FUNC(glGetnUniformiv)
            INIT_BACKENDGL_FUNC(glGetnUniformuiv)
            INIT_BACKENDGL_FUNC(glMinSampleShading)
            INIT_BACKENDGL_FUNC(glPatchParameteri)
            INIT_BACKENDGL_FUNC(glTexParameterIiv)
            INIT_BACKENDGL_FUNC(glTexParameterIuiv)
            INIT_BACKENDGL_FUNC(glGetTexParameterIiv)
            INIT_BACKENDGL_FUNC(glGetTexParameterIuiv)
            INIT_BACKENDGL_FUNC(glSamplerParameterIiv)
            INIT_BACKENDGL_FUNC(glSamplerParameterIuiv)
            INIT_BACKENDGL_FUNC(glGetSamplerParameterIiv)
            INIT_BACKENDGL_FUNC(glGetSamplerParameterIuiv)
            INIT_BACKENDGL_FUNC(glTexBuffer)
            INIT_BACKENDGL_FUNC(glTexBufferRange)
            INIT_BACKENDGL_FUNC(glTexStorage3DMultisample)
            INIT_BACKENDGL_FUNC(glMapBufferRange)
            INIT_BACKENDGL_FUNC(glBufferStorage)
            INIT_BACKENDGL_FUNC(glBufferStorageEXT)
            INIT_BACKENDGL_FUNC(glGetQueryObjectivEXT)
            INIT_BACKENDGL_FUNC(glGetQueryObjecti64vEXT)
            INIT_BACKENDGL_FUNC(glGetQueryObjectui64vEXT)
            INIT_BACKENDGL_FUNC(glBindFragDataLocationEXT)
            INIT_BACKENDGL_FUNC(glMapBufferOES)
            INIT_BACKENDGL_FUNC(glMultiDrawArraysIndirectEXT)
            INIT_BACKENDGL_FUNC(glMultiDrawElementsIndirectEXT)
            INIT_BACKENDGL_FUNC(glMultiDrawElementsBaseVertexEXT)
        }
        return true;
    }

    bool AcquireEGLFunctions(External::EGLFunctionsTable& funcs, std::string customLibPath) {
#if defined(__APPLE__)
        std::vector<std::string> EGLLibNames = {"libEGL.dylib"};
#else
        std::vector<std::string> EGLLibNames = {"libEGL.so"};
#endif
        if (!customLibPath.empty()) {
            EGLLibNames.insert(EGLLibNames.begin(), customLibPath);
        }
        void* eglLib = OpenLib(EGLLibNames);
        if (!eglLib) {
            return false;
        }
#define INIT_EGL_FUNC(name)                                                                                            \
    do {                                                                                                               \
        funcs.name = (External::EGL::name##_PTR)ProcAddress(eglLib, #name);                                            \
    } while (0);

        {
            INIT_EGL_FUNC(eglBindAPI)
            INIT_EGL_FUNC(eglBindTexImage)
            INIT_EGL_FUNC(eglChooseConfig)
            INIT_EGL_FUNC(eglCopyBuffers)
            INIT_EGL_FUNC(eglCreateContext)
            INIT_EGL_FUNC(eglCreatePbufferFromClientBuffer)
            INIT_EGL_FUNC(eglCreatePbufferSurface)
            INIT_EGL_FUNC(eglCreatePixmapSurface)
            INIT_EGL_FUNC(eglCreatePlatformPixmapSurface)
            INIT_EGL_FUNC(eglCreatePlatformWindowSurface)
            INIT_EGL_FUNC(eglCreateWindowSurface)
            INIT_EGL_FUNC(eglDestroyContext)
            INIT_EGL_FUNC(eglDestroySurface)
            INIT_EGL_FUNC(eglGetConfigAttrib)
            INIT_EGL_FUNC(eglGetConfigs)
            INIT_EGL_FUNC(eglGetCurrentContext)
            INIT_EGL_FUNC(eglGetCurrentDisplay)
            INIT_EGL_FUNC(eglGetCurrentSurface)
            INIT_EGL_FUNC(eglGetDisplay)
            INIT_EGL_FUNC(eglGetPlatformDisplay)
            INIT_EGL_FUNC(eglGetError)
            INIT_EGL_FUNC(eglGetProcAddress)
            INIT_EGL_FUNC(eglInitialize)
            INIT_EGL_FUNC(eglMakeCurrent)
            INIT_EGL_FUNC(eglQueryAPI)
            INIT_EGL_FUNC(eglQueryContext)
            INIT_EGL_FUNC(eglQueryString)
            INIT_EGL_FUNC(eglQuerySurface)
            INIT_EGL_FUNC(eglReleaseTexImage)
            INIT_EGL_FUNC(eglReleaseThread)
            INIT_EGL_FUNC(eglSurfaceAttrib)
            INIT_EGL_FUNC(eglSwapBuffers)
            INIT_EGL_FUNC(eglSwapBuffersWithDamageEXT)
            INIT_EGL_FUNC(eglSwapInterval)
            INIT_EGL_FUNC(eglTerminate)
            INIT_EGL_FUNC(eglUnlockSurfaceKHR)
            INIT_EGL_FUNC(eglWaitClient)
            INIT_EGL_FUNC(eglWaitGL)
            INIT_EGL_FUNC(eglWaitNative)
            INIT_EGL_FUNC(eglCreateSync)
            INIT_EGL_FUNC(eglDestroySync)
            INIT_EGL_FUNC(eglClientWaitSync)
            INIT_EGL_FUNC(eglGetSyncAttrib)
            INIT_EGL_FUNC(eglCreateImage)
            INIT_EGL_FUNC(eglDestroyImage)
            INIT_EGL_FUNC(eglGetPlatformDisplay)
            INIT_EGL_FUNC(eglWaitSync)
        }
        return true;
    }

    bool FillInBackendGLCapabilities(External::BackendGLCapabilities& caps,
                                     const External::BackendGLFunctionsTable& glFuncs) {
        if (!glFuncs.glGetString || !glFuncs.glGetIntegerv) {
            return false;
        }

        // glGetString returns null without a current context; never feed
        // that into std::string.
        auto safeString = [](const GLubyte* s) {
            return s ? std::string(reinterpret_cast<const char*>(s)) : std::string{};
        };

        glFuncs.glGetIntegerv(GL_MAJOR_VERSION, (GLint*)&caps.Version[0]);
        glFuncs.glGetIntegerv(GL_MINOR_VERSION, (GLint*)&caps.Version[1]);

        caps.VersionString = safeString(glFuncs.glGetString(GL_VERSION));
        caps.RendererString = safeString(glFuncs.glGetString(GL_RENDERER));
        caps.VendorString = safeString(glFuncs.glGetString(GL_VENDOR));
        caps.ShadingLanguageVersionString = safeString(glFuncs.glGetString(GL_SHADING_LANGUAGE_VERSION));

        GLint extCount = 0;
        glFuncs.glGetIntegerv(GL_NUM_EXTENSIONS, &extCount);
        for (GLint i = 0; glFuncs.glGetStringi && i < extCount; ++i) {
            const char* extension = (const char*)glFuncs.glGetStringi(GL_EXTENSIONS, i);
            if (extension) {
                if (std::strcmp(extension, "GL_EXT_buffer_storage") == 0) {
                    caps.SupportsPersistentMapping = true;
                }
                if (std::strcmp(extension, "GL_EXT_texture_norm16") == 0) {
                    caps.SupportsNorm16Texture = true;
                }
            }
        }

        glFuncs.glGetIntegerv(GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT, &caps.UniformBufferOffsetAlignment);

        return true;
    }
} // namespace SFPEW::Utils::BackendLoader
