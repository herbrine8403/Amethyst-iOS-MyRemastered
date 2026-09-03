from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
HEADER = (ROOT / "Natives/PLThemeManager.h").read_text()
SOURCE = (ROOT / "Natives/PLThemeManager.m").read_text()
PREFERENCES = (ROOT / "Natives/PLPreferences.m").read_text()
CMAKE = (ROOT / "Natives/CMakeLists.txt").read_text()


class ThemePackContracts(unittest.TestCase):
    def test_theme_manager_is_built(self):
        self.assertIn("PLThemeManager.m", CMAKE)

    def test_default_theme_is_registered(self):
        self.assertIn('@"theme_pack": @"pcl-classic"', PREFERENCES)
        self.assertTrue((ROOT / "Natives/resources/themes/pcl-classic/manifest.json").exists())
        self.assertTrue((ROOT / "Natives/resources/themes/pcl-classic/colors.json").exists())

    def test_theme_switch_publishes_notification(self):
        self.assertIn("PLThemeDidChangeNotification", HEADER)
        self.assertIn("postNotificationName:PLThemeDidChangeNotification", SOURCE)

    def test_invalid_theme_falls_back(self):
        self.assertIn("PLDefaultThemeIdentifier", SOURCE)
        self.assertIn("isSafeIdentifier", SOURCE)
        self.assertIn("stringByStandardizingPath", SOURCE)

    def test_missing_tokens_have_fallbacks(self):
        self.assertIn("colorForToken:(NSString *)token fallback:", SOURCE)
        self.assertIn("return fallback;", SOURCE)
        self.assertIn("return nil;", SOURCE)


if __name__ == "__main__":
    unittest.main()
