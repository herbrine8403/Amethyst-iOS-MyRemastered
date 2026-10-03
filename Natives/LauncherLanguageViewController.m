#import "LauncherLanguageViewController.h"

#import "utils.h"

// ★ [LANG-SWITCH] 语言切换后广播；各页收到后 reloadData / 重取 localize() 文案。
NSString * const AmeLauncherLanguageChangedNotification = @"AmeLauncherLanguageChanged";

@interface LauncherLanguageViewController () <UISearchResultsUpdating>

// ★ [LANG-SWITCH] 全部语言代码（按显示名排序，来自 .lproj 枚举）
@property (nonatomic, copy) NSArray<NSString *> *availableCodes;
// ★ [LANG-SWITCH] 搜索过滤后的结果；nil 表示未搜索（直接显示 availableCodes）
@property (nonatomic, copy) NSArray<NSString *> *filteredCodes;
@property (nonatomic, strong) UISearchController *searchController;

@end

@implementation LauncherLanguageViewController

- (instancetype)init {
    // ★ [LANG-SWITCH] 与设置页一致的 insetGrouped 分组样式（iOS 设置 App 观感）。
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // ★ [LANG-SWITCH] 标题走既有 i18n 机制。
    self.title = localize(@"preference.lang.title", @"语言");
    self.availableCodes = AmeLauncherAvailableLanguageCodes();

    // ★ [LANG-SWITCH] 语言较多（几十项），加搜索栏便于查找。
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = localize(@"preference.lang.search_placeholder", @"搜索语言");
    self.searchController.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchController.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    self.tableView.rowHeight = 44;
}

#pragma mark - 数据

// section 0 → nil（= 跟随系统）；section 1 → 具体语言代码。
- (nullable NSString *)codeForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) return nil;
    if (self.filteredCodes) {
        return (indexPath.row < (NSInteger)self.filteredCodes.count) ? self.filteredCodes[indexPath.row] : nil;
    }
    return (indexPath.row < (NSInteger)self.availableCodes.count) ? self.availableCodes[indexPath.row] : nil;
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    return self.filteredCodes ? self.filteredCodes.count : self.availableCodes.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return localize(@"preference.lang.section.system", @"系统");
    return localize(@"preference.lang.section.available", @"可用语言");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"AmeLanguageCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
    }
    cell.textLabel.textColor = [UIColor labelColor];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    NSString *currentOverride = AmeLauncherPreferredLanguageOverride();

    if (indexPath.section == 0) {
        // 「跟随系统」：副标题给出当前系统语言，让该项含义明确。
        cell.textLabel.text = localize(@"preference.lang.follow_system", @"跟随系统");
        NSString *sysCode = [NSLocale preferredLanguages].firstObject ?: @"";
        NSString *sysName = AmeLauncherDisplayNameForLanguageCode(sysCode);
        cell.detailTextLabel.text = sysName.length ? sysName : nil;
        cell.accessoryType = (currentOverride.length == 0) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    } else {
        NSString *code = [self codeForRowAtIndexPath:indexPath];
        cell.textLabel.text = AmeLauncherDisplayNameForLanguageCode(code);
        // 副标题给出原始代码，显示名有歧义时便于确认。
        cell.detailTextLabel.text = code;
        cell.accessoryType = (code && [code isEqualToString:currentOverride])
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    }
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    // section 0 → nil（跟随系统）
    NSString *code = [self codeForRowAtIndexPath:indexPath];

    NSString *before = AmeLauncherPreferredLanguageOverride() ?: @"";
    NSString *after = code ?: @"";
    // ★ [LANG-SWITCH] 持久化到自定义键（不碰系统 AppleLanguages）。
    AmeLauncherSetPreferredLanguageOverride(code);

    [tableView reloadData];
    if (self.searchController.isActive) {
        self.searchController.active = NO;
    }

    if (![before isEqualToString:after]) {
        // ★ [LANG-SWITCH] 即时生效：广播出去，各页收到后 reloadData 重取 localize() 文案。
        [[NSNotificationCenter defaultCenter] postNotificationName:AmeLauncherLanguageChangedNotification
                                                            object:nil];
        // 诚实提示：会 reloadData 的界面（本设置页/主页等）即时生效；少数在视图构建时
        // 一次性取好文案、之后不再重取的页面，需重启启动器才会完全刷新。
        [self showRestartHint];
    }
}

#pragma mark - 重启提示

- (void)showRestartHint {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:localize(@"preference.lang.restart_hint.title", @"语言已切换")
                         message:localize(@"preference.lang.restart_hint.message",
                             @"界面已按新语言刷新。若个别页面仍显示旧语言，请重启启动器使其完全生效。")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UISearchResultsUpdating

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = [searchController.searchBar.text stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (query.length == 0) {
        self.filteredCodes = nil;
        [self.tableView reloadData];
        return;
    }
    NSString *lower = query.lowercaseString;
    NSMutableArray<NSString *> *results = [NSMutableArray array];
    for (NSString *code in self.availableCodes) {
        NSString *name = AmeLauncherDisplayNameForLanguageCode(code);
        if ([name.lowercaseString containsString:lower] || [code.lowercaseString containsString:lower]) {
            [results addObject:code];
        }
    }
    self.filteredCodes = results;
    [self.tableView reloadData];
}

@end
