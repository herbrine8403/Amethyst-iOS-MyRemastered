"""Fast regression checks for renderer and resource-download wiring.

These tests intentionally inspect source contracts so they can run on Windows without Xcode.
The macOS CI build remains responsible for Objective-C compilation.
"""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


def source(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


class RendererContracts(unittest.TestCase):
    def test_auto_has_one_canonical_resolution(self) -> None:
        preferences = source("Natives/LauncherPreferences.m")
        self.assertIn("NSString *PLResolveRendererKey", preferences)
        self.assertRegex(
            preferences,
            r'isEqualToString:@"auto"\]\s*\?\s*@\s*RENDERER_NAME_MTL_ANGLE',
        )
        self.assertIn("PLResolveRendererKey(selectedRenderer)", source("Natives/JavaLauncher.m"))
        self.assertIn(
            'PLResolveRendererKey(NSProcessInfo.processInfo.environment[@"AMETHYST_RENDERER"])',
            source("Natives/egl_bridge.m"),
        )

    def test_profile_default_is_distinct_from_explicit_auto(self) -> None:
        preferences = source("Natives/LauncherPreferences.m")
        settings = source("Natives/ProfileSettingsViewController.m")
        self.assertIn("NSString * const PLProfileInheritedValue", preferences)
        self.assertIn("PLProfileInheritedDisplayName()", preferences)
        self.assertIn("[(NSString *)profileRenderer length] > 0", settings)
        self.assertIn("[(NSString *)profileGraphicsApi length] > 0", settings)
        self.assertIn('[existing removeObjectForKey:@"renderer"]', settings)
        self.assertIn('[existing removeObjectForKey:@"graphicsApi"]', settings)
        self.assertIn("PLNormalizeRendererKey(self.selectedRenderer)", settings)
        self.assertNotIn(
            '[self.selectedRenderer isEqualToString:@"(default)"]', settings
        )
        self.assertNotIn(
            '[self.selectedGraphicsApi isEqualToString:@"(default)"]', settings
        )

    def test_graphics_api_has_whitelist_normalization(self) -> None:
        preferences = source("Natives/LauncherPreferences.m")
        profiles = source("Natives/PLProfiles.m")
        settings = source("Natives/ProfileSettingsViewController.m")
        self.assertIn("NSString *PLNormalizeGraphicsApiKey", preferences)
        self.assertIn("![getGraphicsApiKeys(NO) containsObject:key]", preferences)
        self.assertGreaterEqual(profiles.count("PLNormalizeGraphicsApiKey"), 2)
        self.assertGreaterEqual(settings.count("PLNormalizeGraphicsApiKey"), 2)

    def test_explicit_unknown_target_profile_does_not_fall_back(self) -> None:
        profiles = source("Natives/PLProfiles.m")
        resolver = profiles[
            profiles.index("+ (nullable NSString *)effectiveProfileNameForPreferredName:") :
            profiles.index("- (id)initWithCurrentInstance")
        ]
        self.assertIn("if (preferredName.length > 0)", resolver)
        self.assertIn("? preferredName : nil", resolver)
        self.assertIn("if (effectiveName.length == 0) return nil", resolver)
        self.assertIn("if (!baseDirectory.isAbsolutePath) return nil", resolver)
        self.assertIn("![resolvedPath hasPrefix:basePrefix]", resolver)

    def test_launch_panels_do_not_overwrite_global_renderer(self) -> None:
        for relative in (
            "Natives/LauncherRightPanelViewController.m",
            "Natives/VersionManagerViewController.m",
        ):
            text = source(relative)
            self.assertNotRegex(text, r'setPrefString\(@"video\.(renderer|graphics_api)"')


class ResourceContracts(unittest.TestCase):
    SERVICES = (
        "ModService",
        "ShaderService",
        "ResourcePackService",
        "DataPackService",
        "WorldService",
    )

    def test_download_source_reaches_version_request(self) -> None:
        download = source("Natives/DownloadViewController.m")
        self.assertIn("initialSource = modItem.apiSource", download)
        self.assertIn("initialSource = shaderItem.apiSource", download)
        self.assertIn("apiSource = item.apiSource", download)
        asset_versions = source("Natives/AssetVersionViewController.m")
        self.assertIn("if (self.apiSource == 2)", asset_versions)
        self.assertIn("[CurseForgeAPI sharedInstance]", asset_versions)

    def test_download_target_profile_is_preserved(self) -> None:
        header = source("Natives/DownloadViewController.h")
        implementation = source("Natives/DownloadViewController.m")
        self.assertIn("targetProfileName", header)
        self.assertGreaterEqual(implementation.count("[self effectiveTargetProfileName]"), 7)

        expected_tabs = {
            "Mods": 1,
            "Shaders": 2,
            "ResourcePacks": 3,
            "DataPacks": 4,
            "Worlds": 6,
        }
        for manager, tab in expected_tabs.items():
            text = source(f"Natives/{manager}ManagerViewController.m")
            self.assertRegex(text, rf"(?:downloadVC|vc)\.initialTabIndex = {tab};")
            self.assertRegex(
                text, r"(?:downloadVC|vc)\.targetProfileName = self\.profileName;"
            )

    def test_resource_services_publish_terminal_completion(self) -> None:
        for service in self.SERVICES:
            text = source(f"Natives/{service}.m")
            self.assertIn("completedWithError:", text)
            self.assertNotRegex(
                text,
                r'setTaskWithId:[^;]+state:DownloadTaskState(?:Completed|Failed)',
            )

    def test_paths_use_the_shared_profile_resolver(self) -> None:
        for service in self.SERVICES:
            text = source(f"Natives/{service}.m")
            self.assertIn("resolvedGameDirectoryForProfileName", text)

        self.assertIn(
            "if (gameDir.length == 0) return nil",
            source("Natives/ResourcePackService.m"),
        )
        self.assertIn(
            "if (gameDir.length == 0) return nil",
            source("Natives/WorldService.m"),
        )

    def test_profile_aware_service_headers_accept_an_unspecified_target(self) -> None:
        for service in self.SERVICES:
            header = source(f"Natives/{service}.h")
            self.assertIn("NSString * _Nullable)profileName", header)
        profiles = source("Natives/PLProfiles.h")
        self.assertIn("effectiveProfileNameForPreferredName:(nullable NSString *)", profiles)
        self.assertIn("resolvedGameDirectoryForProfileName:(nullable NSString *)", profiles)

    def test_explicit_invalid_profile_never_falls_back_to_shared_game_dir(self) -> None:
        for service_name, existing_method, ensure_method in (
            ("ModService", "existingModsFolderForProfile", "ensureModsFolderForProfile"),
            (
                "ShaderService",
                "existingShadersFolderForProfile",
                "ensureShadersFolderForProfile",
            ),
        ):
            text = source(f"Natives/{service_name}.m")
            start = text.index(f"- (nullable NSString *){existing_method}")
            end = text.index("#pragma mark", start)
            folder_methods = text[start:end]
            self.assertIn("resolvedGameDir.length == 0", folder_methods)
            self.assertIn(ensure_method, folder_methods)
            self.assertNotIn('getenv("POJAV_GAME_DIR")', folder_methods)

        resource_pack = source("Natives/ResourcePackService.m")
        download = resource_pack[
            resource_pack.index("- (void)downloadResourcePack:") :
            resource_pack.index("#pragma mark - PLDownloadClient", resource_pack.index("- (void)downloadResourcePack:"))
        ]
        self.assertIn("ensureResourcePacksFolderForProfile:profileName", download)
        self.assertNotIn("PLProfiles.current.profiles", download)
        self.assertNotIn('getenv("POJAV_GAME_DIR")', download)

        shader = source("Natives/ShaderService.m")
        shader_download = shader[
            shader.index("- (void)downloadShader:") :
            shader.index("#pragma mark - PLDownloadClient", shader.index("- (void)downloadShader:"))
        ]
        self.assertIn("ensureShadersFolderForProfile:profileName", shader_download)
        self.assertNotIn('profileName.length ? profileName : @"default"', shader_download)

    def test_completed_transfer_is_not_shown_as_downloading_100_percent(self) -> None:
        manager = source("Natives/DownloadTaskManager.m")
        task_ui = source("Natives/DownloadTasksViewController.m")
        detail_ui = source("Natives/PLTaskProgressViewController.m")
        self.assertIn("item.progress = transferComplete ? 0.99 : progress", manager)
        self.assertIn("stage.progress = transferComplete ? 0.99 : progress", manager)
        self.assertIn("DownloadTaskUserInfoTransferCompleteKey", task_ui)
        self.assertIn("DownloadTaskUserInfoTransferCompleteKey", detail_ui)
        self.assertIn("PLDownloadTaskStateIsTerminal(oldState)", manager)
        self.assertIn("floor(clamped * 1000.0)", task_ui)
        self.assertIn("MIN(99", detail_ui)

    def test_immediate_cache_hit_cannot_be_written_back_to_downloading(self) -> None:
        manager = source("Natives/DownloadTaskManager.m")
        self.assertIn("PLDownloadTaskStateIsTerminal(item.state)", manager)
        for service in self.SERVICES[:-1]:
            text = source(f"Natives/{service}.m")
            start = text.index("startRequest:request")
            mark_downloading = text.index("state:DownloadTaskStateDownloading", start)
            unlock_after_registration = text.index(
                "[self.downloadStateLock unlock]", mark_downloading
            )
            self.assertGreater(unlock_after_registration, mark_downloading)

    def test_retry_cannot_rebuild_an_active_task_twice(self) -> None:
        manager = source("Natives/DownloadTaskManager.m")
        retry_method = manager[manager.index("- (void)retryTaskWithId:") :]
        state_guard = retry_method.index("item.state != DownloadTaskStateFailed")
        reset_pending = retry_method.index("item.state = DownloadTaskStatePending")
        self.assertLess(state_guard, reset_pending)
        self.assertIn("item.state != DownloadTaskStateCancelled", retry_method)
        self.assertIn("item.state != DownloadTaskStatePaused", retry_method)

    def test_paused_weak_raw_task_can_be_recreated(self) -> None:
        manager = source("Natives/DownloadTaskManager.m")
        resume_method = manager[
            manager.index("- (void)resumeTaskWithId:") : manager.index(
                "- (void)cancelTaskWithId:"
            )
        ]
        self.assertIn(
            "!rawTask && state == DownloadTaskStatePaused && item.retryHandler",
            resume_method,
        )
        self.assertIn("[self retryTaskWithId:taskId]", resume_method)

    def test_mod_and_shader_pagination_state_is_independent(self) -> None:
        download = source("Natives/DownloadViewController.m")
        self.assertNotIn("isLoadingMore", download)
        self.assertNotIn("currentSearchQuery", download)
        for token in (
            "isLoadingMods",
            "isLoadingShaders",
            "modRequestGeneration",
            "shaderRequestGeneration",
            "modSearchQuery",
            "shaderSearchQuery",
        ):
            self.assertIn(token, download)
        self.assertIn("case 1: [self refreshModList]", download)
        self.assertIn("case 2: [self refreshShaderList]", download)

    def test_world_archive_is_staged_and_never_extracted_into_saves(self) -> None:
        world = source("Natives/WorldService.m")
        self.assertIn('PLWorldStagingRootName = @".amethyst-world-staging"', world)
        self.assertGreaterEqual(
            world.count("createWorldStagingDirectoryForSavesDir"), 4
        )
        self.assertIn("downloadStagingDirectories", world)
        stage_method = world[
            world.index("- (nullable PLStagedWorld *)stageWorldZipAt:") :
            world.index("- (nullable NSString *)commitStagedWorld:")
        ]
        self.assertIn("extractFilesTo:extractDirectory overwrite:NO", stage_method)
        self.assertNotIn("overwrite:YES", world)
        self.assertNotIn("extractFilesTo:savesDir", world)
        self.assertIn("archiveEntries:entries areSafeUnderDirectory", stage_method)

        commit_method = world[
            world.index("- (nullable NSString *)commitStagedWorld:") :
            world.index("- (BOOL)isWorldTaskItemCurrent:")
        ]
        self.assertIn("if ([fm fileExistsAtPath:destination]) continue", commit_method)
        self.assertIn("moveItemAtPath:source toPath:destination", commit_method)
        self.assertIn('stringWithFormat:@"%@_%ld"', commit_method)
        move = commit_method.index("moveItemAtPath:source toPath:destination")
        rollback = commit_method.index("removeItemAtPath:destination")
        self.assertLess(move, rollback)

    def test_world_archive_requires_one_safe_visible_world(self) -> None:
        world = source("Natives/WorldService.m")
        self.assertIn("worldDirectoryContainingLevelDatUnderPath", world)
        self.assertIn("level.dat is missing", world)
        self.assertIn("multiple ambiguous worlds", world)
        self.assertIn("NSFileTypeSymbolicLink", world)
        self.assertIn("NSFileTypeRegular", world)
        self.assertIn("sanitizedWorldDirectoryName", world)
        self.assertIn("PLWorldDownloadGenerationKey", world)
        self.assertIn("taskItem.maxRetryCount = 0", world)
        self.assertIn("downloadWorldNames[newTask] = capturedWorldName", world)
        self.assertIn("downloadSavesFolders[newTask] = capturedSavesFolder", world)
        self.assertNotIn("task.taskDescription", world)
        self.assertNotIn("componentsSeparatedByString:@\"\\n\"", world)
        self.assertIn("taskItemRef.rawTask = newTask", world)
        self.assertIn("PLTaskStagesWorld()", world)

    def test_world_pause_and_cancel_do_not_report_failure_or_success(self) -> None:
        world = source("Natives/WorldService.m")
        self.assertIn("error.code == NSURLErrorCancelled", world)
        self.assertIn("if (isCancellation)", world)
        current_guard = world[
            world.index("- (BOOL)isWorldTaskItemCurrent:") :
            world.index("#pragma mark - 在线世界下载")
        ]
        self.assertIn("latestTask.state == DownloadTaskStateDownloading", current_guard)
        self.assertIn(
            "[latestTask.userInfo[PLWorldDownloadGenerationKey] isEqual:generation]",
            current_guard,
        )
        self.assertGreaterEqual(world.count("isWorldTaskItemCurrent"), 7)
        online_finish = world[world.index("didFinishDownloadingToURL:") :]
        commit = online_finish.index("commitStagedWorld:stagedWorld")
        gate = online_finish.rfind("isWorldTaskItemCurrent", 0, commit)
        main_queue = online_finish.rfind("dispatch_get_main_queue()", 0, commit)
        self.assertGreaterEqual(gate, 0)
        self.assertGreaterEqual(main_queue, 0)
        self.assertLess(main_queue, gate)
        self.assertIn("taskItem.supportsResume = NO", world)
        self.assertIn("taskItemRef.supportsResume = YES", world)
        self.assertIn("[fm removeItemAtPath:installedWorldPath error:nil]", world)
        self.assertIn("[manager retryTaskWithId:taskItem.taskId]", world)

    def test_local_world_import_reports_100_only_after_safe_commit(self) -> None:
        world = source("Natives/WorldService.m")
        import_method = world[
            world.index("- (void)importWorldFromURL:") :
            world.index("#pragma mark - NSURLSessionDownloadDelegate")
        ]
        commit = import_method.index("commitStagedWorld:stagedWorld")
        completed = import_method.index("prog.completedUnitCount = 1")
        self.assertLess(commit, completed)
        self.assertIn("cleanupWorldStagingDirectory:stagingDirectory", import_method)


if __name__ == "__main__":
    unittest.main()
