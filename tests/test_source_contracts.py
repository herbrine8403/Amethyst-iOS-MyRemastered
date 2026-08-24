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
        settings = source("Natives/ProfileSettingsViewController.m")
        self.assertIn("[(NSString *)profileRenderer length] > 0", settings)
        self.assertIn("[(NSString *)profileGraphicsApi length] > 0", settings)
        self.assertIn('[existing removeObjectForKey:@"renderer"]', settings)
        self.assertIn("PLNormalizeRendererKey(self.selectedRenderer)", settings)

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

    def test_world_archive_must_contain_a_directly_visible_world(self) -> None:
        world = source("Natives/WorldService.m")
        self.assertIn("worldDirectoryContainingLevelDatUnderPath", world)
        self.assertIn("level.dat is missing", world)
        self.assertIn("BOOL finalWorldDirExistedBefore = NO", world)
        self.assertIn("PLWorldDownloadGenerationKey", world)
        self.assertIn("taskItem.maxRetryCount = 0", world)
        self.assertIn("newTask.taskDescription = capturedTaskDescription", world)
        self.assertIn("taskItemRef.rawTask = newTask", world)
        self.assertIn("PLTaskStagesWorld()", world)

    def test_world_pause_and_cancel_do_not_report_failure_or_success(self) -> None:
        world = source("Natives/WorldService.m")
        self.assertIn("error.code == NSURLErrorCancelled", world)
        self.assertIn("if (isCancellation)", world)
        self.assertIn(
            "latestTask.state != DownloadTaskStateDownloading",
            world,
        )
        self.assertIn(
            "![latestTask.userInfo[PLWorldDownloadGenerationKey] isEqual:generation]",
            world,
        )
        self.assertIn("[manager retryTaskWithId:taskItem.taskId]", world)


if __name__ == "__main__":
    unittest.main()
