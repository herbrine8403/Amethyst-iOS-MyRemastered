//
//  ServerListViewController.m
//  Amethyst
//

#import "ServerListViewController.h"
#import "BackgroundManager.h"
#import "InlineMessageView.h"
#import "PLPreferences.h"
#import "PLProfiles.h"
#import "ServerService.h"
#import "ServerItem.h"
#import "ServerDetailViewController.h"
#import "installer/modpack/ModrinthAPI.h"
#import "installer/modpack/CurseForgeAPI.h"
#import "installer/CurseForgeAPIKeyViewController.h"
#import "UIKit+AFNetworking.h"
#import "utils.h"

@interface ServerListViewController ()
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UISegmentedControl *sourceSegment;
@property (nonatomic, strong) NSArray<ServerItem *> *serverList;
@property (nonatomic, strong) InlineMessageView *currentMessageView;
@property (nonatomic, assign) ServerDownloadAPI currentAPI;
@property (nonatomic, copy) NSString *searchQuery;
@property (nonatomic, assign) NSInteger currentOffset;
@property (nonatomic, assign) BOOL hasMore;
@property (nonatomic, assign) BOOL isLoading;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@end

@implementation ServerListViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // 适配自定义启动器背景：将当前视图控制器透明化，使全局背景壁纸能够透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    [[BackgroundManager sharedManager] applyEffectToView:self.view];
    self.title = localize(@"i18n_str_880", nil);
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = 88;

    // 顶部源切换（放在导航栏 titleView 位置，固定每段宽度避免被系统拉伸/压缩）
    self.sourceSegment = [[UISegmentedControl alloc] initWithItems:@[@"Modrinth", @"CurseForge"]];
    [self.sourceSegment setWidth:90 forSegmentAtIndex:0];
    [self.sourceSegment setWidth:90 forSegmentAtIndex:1];
    self.sourceSegment.selectedSegmentIndex = 0;
    [self.sourceSegment addTarget:self action:@selector(sourceChanged:) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.sourceSegment;

    // 搜索控制器
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = localize(@"i18n_str_973", nil);
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    // 关闭按钮
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                                                          target:self
                                                                                          action:@selector(actionClose)];

    // 加载指示器（导航栏右侧）
    self.loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:self.loadingIndicator];

    self.currentAPI = [ServerService currentAPI];
    [self.sourceSegment setSelectedSegmentIndex:(self.currentAPI == ServerDownloadAPICurseForge) ? 1 : 0];

    self.serverList = @[];
    self.hasMore = YES;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleBackgroundUIEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    [self loadServerList];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"BackgroundUIEffectChanged" object:nil];
}

- (void)actionClose {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)handleBackgroundUIEffectChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 重新应用透明化，确保背景效果切换后视图仍能透出全局背景
        [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
        [[BackgroundManager sharedManager] applyEffectToView:self.view];
        [self.tableView reloadData];
    });
}

#pragma mark - 源切换

- (void)sourceChanged:(UISegmentedControl *)sender {
    ServerDownloadAPI newAPI = (sender.selectedSegmentIndex == 1) ? ServerDownloadAPICurseForge : ServerDownloadAPIModrinth;

    // ★ [MODPACK-FIX] CurseForge 切换前校验：免 key 可用（无 key 时 baseURL 强制落 MCIM 镜像，
    // 实测 200），门控改用 isSourceAvailable——key 仅官方直连需要。
    if (newAPI == ServerDownloadAPICurseForge && ![CurseForgeAPI isSourceAvailable]) {
        InlineMessageView *msg = [InlineMessageView showInViewController:self
                                                                  title:localize(@"i18n_str_171", nil)
                                                               message:localize(@"i18n_str_172", nil)
                                                                  type:InlineMessageTypeInfo];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [msg dismiss];
            // 恢复选择到 Modrinth
            [sender setSelectedSegmentIndex:0];
            [self openCurseForgeAPIKeySettings];
        });
        return;
    }

    self.currentAPI = newAPI;
    [PLPreferences setDownloadSource:(newAPI == ServerDownloadAPICurseForge) ? @"curseforge" : @"modrinth" forType:@"server"];
    self.currentOffset = 0;
    self.hasMore = YES;
    self.serverList = @[];
    [self.tableView reloadData];
    [self loadServerList];
}

- (void)openCurseForgeAPIKeySettings {
    CurseForgeAPIKeyViewController *vc = [[CurseForgeAPIKeyViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - 搜索

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(reloadSearch) object:nil];
    [self performSelector:@selector(reloadSearch) withObject:nil afterDelay:0.5];
}

- (void)reloadSearch {
    self.searchQuery = self.searchController.searchBar.text ?: @"";
    self.currentOffset = 0;
    self.hasMore = YES;
    self.serverList = @[];
    [self.tableView reloadData];
    [self loadServerList];
}

#pragma mark - 数据加载

- (void)loadServerList {
    if (self.isLoading) return;
    self.isLoading = YES;
    if (self.currentOffset == 0) {
        [self.loadingIndicator startAnimating];
        self.currentMessageView = [InlineMessageView showInViewController:self
                                                                    title:localize(@"i18n_str_974", nil)
                                                                 message:nil
                                                                    type:InlineMessageTypeLoading];
    }

    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"limit"] = @30;
    filters[@"offset"] = @(self.currentOffset);
    if (self.searchQuery.length > 0) {
        filters[@"query"] = self.searchQuery;
    }

    __weak typeof(self) weakSelf = self;
    [[ServerService sharedService] searchServersWithAPI:self.currentAPI
                                                filters:filters
                                             completion:^(NSArray<ServerItem *> *servers, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.loadingIndicator stopAnimating];
        [strongSelf.currentMessageView dismiss];
        strongSelf.currentMessageView = nil;
        strongSelf.isLoading = NO;

        if (error) {
            strongSelf.currentMessageView = [InlineMessageView showInViewController:strongSelf
                                                                              title:localize(@"Error", nil)
                                                                           message:error.localizedDescription
                                                                              type:InlineMessageTypeError];
            return;
        }

        NSMutableArray<ServerItem *> *all = [strongSelf.serverList mutableCopy];
        [all addObjectsFromArray:servers];
        strongSelf.serverList = [all copy];
        strongSelf.hasMore = (servers.count >= 30);
        strongSelf.currentOffset += servers.count;
        [strongSelf.tableView reloadData];

        if (strongSelf.serverList.count == 0) {
            strongSelf.currentMessageView = [InlineMessageView showInViewController:strongSelf
                                                                              title:localize(@"i18n_str_975", nil)
                                                                           message:localize(@"i18n_str_976", nil)
                                                                              type:InlineMessageTypeInfo];
        }
    }];
}

#pragma mark - UITableView DataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.serverList.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"ServerCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
        cell.backgroundColor = [UIColor clearColor];
        cell.contentView.backgroundColor = [UIColor clearColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

        // 毛玻璃卡片
        UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
        blur.translatesAutoresizingMaskIntoConstraints = NO;
        blur.layer.cornerRadius = 12;
        blur.layer.masksToBounds = YES;
        [cell.contentView insertSubview:blur atIndex:0];
        [NSLayoutConstraint activateConstraints:@[
            [blur.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:4],
            [blur.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:12],
            [blur.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-12],
            [blur.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4]
        ]];
        cell.backgroundView = nil;
        cell.textLabel.backgroundColor = [UIColor clearColor];
        cell.detailTextLabel.backgroundColor = [UIColor clearColor];
    }

    ServerItem *item = self.serverList[indexPath.row];

    NSString *title = item.title.length ? item.title : item.serverID;
    cell.textLabel.text = title;
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];

    // 副标题：来源 + 项目类型 + 下载量
    NSString *sourceTag = (item.apiSource == ServerAPISourceCurseForge) ? @"CurseForge" : @"Modrinth";
    NSString *typeTag = item.projectType ?: @"server";
    NSString *downloads = [item formattedDownloads];
    cell.detailTextLabel.text = [NSString stringWithFormat:localize(@"i18n_str_977", nil), sourceTag, typeTag, downloads];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.numberOfLines = 2;

    UIImage *placeholder = [UIImage imageNamed:@"DefaultProfile"];
    [cell.imageView setImageWithURL:[NSURL URLWithString:item.iconURL] placeholderImage:placeholder];
    cell.imageView.layer.cornerRadius = 10;
    cell.imageView.clipsToBounds = YES;
    cell.imageView.contentMode = UIViewContentModeScaleAspectFill;

    // 触底加载更多
    if (self.hasMore && indexPath.row == self.serverList.count - 1) {
        [self loadServerList];
    }

    return cell;
}

#pragma mark - UITableView Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    ServerItem *item = self.serverList[indexPath.row];
    ServerDetailViewController *detail = [[ServerDetailViewController alloc] initWithServerItem:item api:self.currentAPI];
    [self.navigationController pushViewController:detail animated:YES];
}

@end
