#import "WMFArticleViewController_Private.h"
#import "Wikipedia-Swift.h"

// Frameworks
#import <Masonry/Masonry.h>
#import <BlocksKit/BlocksKit+UIKit.h>

// Controller
#import "WebViewController.h"
#import "UIViewController+WMFStoryboardUtilities.h"
#import "WMFArticleHeaderImageGalleryViewController.h"
#import "WMFReadMoreViewController.h"
#import "WMFModalImageGalleryViewController.h"
#import "SectionEditorViewController.h"
#import "WMFArticleFooterMenuViewController.h"
#import "WMFArticleBrowserViewController.h"

//Funnel
#import "WMFShareFunnel.h"
#import "ProtectedEditAttemptFunnel.h"
#import "PiwikTracker+WMFExtensions.h"

// Model
#import "MWKDataStore.h"
#import "MWKCitation.h"
#import "MWKTitle.h"
#import "MWKSavedPageList.h"
#import "MWKUserDataStore.h"
#import "MWKArticle+WMFSharing.h"
#import "MWKHistoryEntry.h"
#import "MWKHistoryList.h"
#import "MWKProtectionStatus.h"
#import "MWKSectionList.h"
#import "MWKHistoryList.h"

// Networking
#import "WMFArticleFetcher.h"

// View
#import "UIViewController+WMFEmptyView.h"
#import "UIBarButtonItem+WMFButtonConvenience.h"
#import "UIScrollView+WMFContentOffsetUtils.h"
#import "UIWebView+WMFTrackingView.h"
#import "NSArray+WMFLayoutDirectionUtilities.h"
#import "UIViewController+WMFOpenExternalUrl.h"

#import "NSString+WMFPageUtilities.h"
#import "NSURL+WMFLinkParsing.h"
#import "NSURL+WMFExtras.h"

@import SafariServices;

@import JavaScriptCore;

@import Tweaks;

NS_ASSUME_NONNULL_BEGIN

@interface WMFArticleViewController ()
<WMFWebViewControllerDelegate,
 UINavigationControllerDelegate,
 WMFArticleHeaderImageGalleryViewControllerDelegate,
 WMFImageGalleryViewControllerDelegate,
 SectionEditorViewControllerDelegate,
 UIViewControllerPreviewingDelegate>

@property (nonatomic, strong, readwrite) MWKTitle* articleTitle;
@property (nonatomic, strong, readwrite) MWKDataStore* dataStore;

@property (strong, nonatomic, nullable, readwrite) WMFShareFunnel* shareFunnel;

// Data
@property (nonatomic, strong, readonly) MWKHistoryEntry* historyEntry;
@property (nonatomic, strong, readonly) MWKSavedPageList* savedPages;
@property (nonatomic, strong, readonly) MWKHistoryList* recentPages;

// Fetchers
@property (nonatomic, strong) WMFArticleFetcher* articleFetcher;
@property (nonatomic, strong, nullable) AnyPromise* articleFetcherPromise;

// Children
@property (nonatomic, strong) WMFArticleHeaderImageGalleryViewController* headerGallery;
@property (nonatomic, strong) WMFReadMoreViewController* readMoreListViewController;

// Views
@property (nonatomic, strong) MASConstraint* headerHeightConstraint;

@property (strong, nonatomic, nullable) NSTimer* significantlyViewedTimer;

// Previewing
@property (nonatomic, weak) id<UIViewControllerPreviewing> linkPreviewingContext;

@property (nonatomic, strong) WMFArticleFooterMenuViewController* footerMenuViewController;
@property (nonatomic, assign) BOOL isPreviewing;

@end

@implementation WMFArticleViewController

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (instancetype)initWithArticleTitle:(MWKTitle*)title
                           dataStore:(MWKDataStore*)dataStore {
    NSParameterAssert(title);
    NSParameterAssert(dataStore);

    self = [super init];
    if (self) {
        self.articleTitle = title;
        self.dataStore    = dataStore;
        [self observeArticleUpdates];
        self.hidesBottomBarWhenPushed = YES;
    }
    return self;
}

#pragma mark - Accessors

- (NSString*)description {
    return [NSString stringWithFormat:@"%@ %@", [super description], self.articleTitle];
}

- (void)setArticle:(nullable MWKArticle*)article {
    NSAssert(self.isViewLoaded, @"Expecting article to only be set after the view loads.");

    if (_article == article) {
        return;
    }

    _footerMenuViewController      = nil;
    _tableOfContentsViewController = nil;
    [self.articleFetcher cancelFetchForPageTitle:_articleTitle];

    _article = article;

    // always update webVC & headerGallery, even if nil so they are reset if needed
    self.webViewController.article = _article;
    [self.headerGallery showImagesInArticle:_article];

    // always update footers
    [self updateArticleFootersIfNeeded];

    if (self.article) {
        [self startSignificantlyViewedTimer];
        [self wmf_hideEmptyView];

        if (!self.article.isMain) {
            [self createTableOfContentsViewController];
            [self fetchReadMore];
        }
    }
}

- (MWKHistoryList*)recentPages {
    return self.dataStore.userDataStore.historyList;
}

- (MWKSavedPageList*)savedPages {
    return self.dataStore.userDataStore.savedPageList;
}

- (MWKHistoryEntry*)historyEntry {
    return [self.recentPages entryForTitle:self.articleTitle];
}

- (nullable WMFShareFunnel*)shareFunnel {
    NSParameterAssert(self.article);
    if (!self.article) {
        return nil;
    }
    if (!_shareFunnel) {
        _shareFunnel = [[WMFShareFunnel alloc] initWithArticle:self.article];
    }
    return _shareFunnel;
}

- (WMFReadMoreViewController*)readMoreListViewController {
    if (!_readMoreListViewController) {
        _readMoreListViewController = [[WMFReadMoreViewController alloc] initWithTitle:self.articleTitle dataStore:self.dataStore];
    }
    return _readMoreListViewController;
}

- (WMFArticleFetcher*)articleFetcher {
    if (!_articleFetcher) {
        _articleFetcher = [[WMFArticleFetcher alloc] initWithDataStore:self.dataStore];
    }
    return _articleFetcher;
}

- (WebViewController*)webViewController {
    if (!_webViewController) {
        _webViewController                      = [WebViewController wmf_initialViewControllerFromClassStoryboard];
        _webViewController.delegate             = self;
        _webViewController.headerViewController = self.headerGallery;
    }
    return _webViewController;
}

- (WMFArticleHeaderImageGalleryViewController*)headerGallery {
    if (!_headerGallery) {
        _headerGallery          = [[WMFArticleHeaderImageGalleryViewController alloc] init];
        _headerGallery.delegate = self;
    }
    return _headerGallery;
}

#pragma mark - Notifications and Observations

- (void)applicationWillResignActiveWithNotification:(NSNotification*)note {
    [self saveWebViewScrollOffset];
}

- (void)articleUpdatedWithNotification:(NSNotification*)note {
    MWKArticle* article = note.userInfo[MWKArticleKey];
    if ([self.articleTitle isEqualToTitle:article.title]) {
        self.article = article;
    }
}

- (void)observeArticleUpdates {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:MWKArticleSavedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(articleUpdatedWithNotification:)
                                                 name:MWKArticleSavedNotification
                                               object:nil];
}

- (void)unobserveArticleUpdates {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:MWKArticleSavedNotification object:nil];
}

#pragma mark - Public

- (BOOL)canRefresh {
    return self.article != nil;
}

- (BOOL)canShare {
    return self.article != nil;
}

- (BOOL)hasLanguages {
    return self.article.languagecount > 1;
}

- (BOOL)hasTableOfContents {
    return self.article != nil && !self.article.isMain;
}

- (NSString*)shareText {
    NSString* text = [self.webViewController selectedText];
    if (text.length == 0) {
        text = [self.article shareSnippet];
    }
    return text;
}

#pragma mark - Article Footers

- (void)updateArticleFootersIfNeeded {
    if (!self.article || self.article.isMain) {
        [self.webViewController setFooterViewControllers:nil];
        return;
    }

    if (self.footerMenuViewController.article != self.article) {
        self.footerMenuViewController = [[WMFArticleFooterMenuViewController alloc] initWithArticle:self.article];
    }
    NSMutableArray* footerVCs = [NSMutableArray arrayWithObject:self.footerMenuViewController];
    if ([self.readMoreListViewController hasResults]) {
        [footerVCs addObject:self.readMoreListViewController];
        [self appendReadMoreTableOfContentsItemIfNeeded];
    }
    [self.webViewController setFooterViewControllers:footerVCs];
}

#pragma mark - Progress

- (void)updateProgress:(CGFloat)progress animated:(BOOL)animated {
    [self.delegate articleController:self didUpdateArticleLoadProgress:progress animated:animated];
}

/**
 *  Some of the progress is in loading the HTML into the webview
 *  This leaves 20% of progress for that work.
 */
- (CGFloat)totalProgressWithArticleFetcherProgress:(CGFloat)progress {
    return 0.8 * progress;
}

#pragma mark - Significantly Viewed Timer

- (void)startSignificantlyViewedTimer {
    if (self.significantlyViewedTimer) {
        return;
    }
    if (!self.article) {
        return;
    }
    MWKHistoryList* historyList = self.dataStore.userDataStore.historyList;
    MWKHistoryEntry* entry      = [historyList entryForTitle:self.articleTitle];
    if (!entry.titleWasSignificantlyViewed) {
        self.significantlyViewedTimer = [NSTimer scheduledTimerWithTimeInterval:FBTweakValue(@"Explore", @"Related items", @"Required viewing time", 30.0) target:self selector:@selector(significantlyViewedTimerFired:) userInfo:nil repeats:NO];
    }
}

- (void)significantlyViewedTimerFired:(NSTimer*)timer {
    [self stopSignificantlyViewedTimer];
    MWKHistoryList* historyList = self.dataStore.userDataStore.historyList;
    [historyList setSignificantlyViewedOnPageInHistoryWithTitle:self.articleTitle];
    [historyList save];
}

- (void)stopSignificantlyViewedTimer {
    [self.significantlyViewedTimer invalidate];
    self.significantlyViewedTimer = nil;
}

#pragma mark - Title Button

- (void)setUpTitleBarButton {
    UIButton* b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b adjustsImageWhenHighlighted];
    UIImage* w = [UIImage imageNamed:@"W"];
    [b setImage:w forState:UIControlStateNormal];
    [b sizeToFit];
    @weakify(self);
    [b bk_addEventHandler:^(id sender) {
        @strongify(self);
        [self.navigationController popToRootViewControllerAnimated:YES];
    } forControlEvents:UIControlEventTouchUpInside];
    self.navigationItem.titleView                        = b;
    self.navigationItem.titleView.isAccessibilityElement = YES;
    self.navigationItem.titleView.accessibilityLabel     = MWLocalizedString(@"home-button-accessibility-label", nil);
    self.navigationItem.titleView.accessibilityTraits   |= UIAccessibilityTraitButton;
}

#pragma mark - ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setUpTitleBarButton];
    self.view.clipsToBounds = NO;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillResignActiveWithNotification:) name:UIApplicationWillResignActiveNotification object:nil];

    [self setupWebView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self registerForPreviewingIfAvailable];
    [self fetchArticleIfNeeded];

    [self startSignificantlyViewedTimer];
    if (self.isPreviewing) {
        [[PiwikTracker sharedInstance] wmf_logActionPreviewDismissedFromSource:self];
        self.isPreviewing = NO;
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [[NSUserDefaults standardUserDefaults] wmf_setOpenArticleTitle:self.articleTitle];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];

    [self stopSignificantlyViewedTimer];
    [self saveWebViewScrollOffset];
    if ([[[NSUserDefaults standardUserDefaults] wmf_openArticleTitle] isEqualToTitle:self.articleTitle]) {
        [[NSUserDefaults standardUserDefaults] wmf_setOpenArticleTitle:nil];
    }
}

- (void)traitCollectionDidChange:(nullable UITraitCollection*)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self registerForPreviewingIfAvailable];
}

#pragma mark - Web View Setup

- (void)setupWebView {
    [self addChildViewController:self.webViewController];
    [self.view addSubview:self.webViewController.view];
    [self.webViewController.view mas_makeConstraints:^(MASConstraintMaker* make) {
        make.leading.trailing.top.and.bottom.equalTo(self.view);
    }];
    [self.webViewController didMoveToParentViewController:self];
}

#pragma mark - Save Offset

- (void)saveWebViewScrollOffset {
    // Don't record scroll position of "main" pages.
    if (self.article.isMain) {
        return;
    }
    CGFloat offset = [self.webViewController currentVerticalOffset];
    if (offset > 0) {
        [self.recentPages setPageScrollPosition:offset onPageInHistoryWithTitle:self.articleTitle];
        [self.recentPages save];
    }
}

#pragma mark - Article Fetching

- (void)fetchArticleIfNeeded {
    NSAssert(self.isViewLoaded, @"Should only fetch article when view is loaded so we can update its state.");
    if (self.article) {
        return;
    }
    [self wmf_showEmptyViewOfType:WMFEmptyViewTypeBlank];
    [self unobserveArticleUpdates];

    @weakify(self);
    self.articleFetcherPromise = [self.articleFetcher fetchLatestVersionOfTitleIfNeeded:self.articleTitle progress:^(CGFloat progress) {
        [self updateProgress:[self totalProgressWithArticleFetcherProgress:progress] animated:YES];
    }].then(^(MWKArticle* article) {
        @strongify(self);
        [self updateProgress:[self totalProgressWithArticleFetcherProgress:1.0] animated:YES];
        self.article = article;
        /*
           NOTE(bgerstle): add side effects to setArticle, not here. this ensures they happen even when falling back to
           cached content
         */
    }).catch(^(NSError* error){
        @strongify(self);
        DDLogError(@"Article Fetch Error: %@", [error localizedDescription]);

        MWKArticle* cachedFallback = error.userInfo[WMFArticleFetcherErrorCachedFallbackArticleKey];
        if (cachedFallback) {
            self.article = cachedFallback;
            if (![error wmf_isNetworkConnectionError]) {
                // don't show offline banner for cached articles
                [[WMFAlertManager sharedInstance] showErrorAlert:error
                                                          sticky:NO
                                           dismissPreviousAlerts:NO
                                                     tapCallBack:NULL];
            }
        } else {
            [self wmf_showEmptyViewOfType:WMFEmptyViewTypeArticleDidNotLoad];
            [[WMFAlertManager sharedInstance] showErrorAlert:error
                                                      sticky:NO
                                       dismissPreviousAlerts:NO
                                                 tapCallBack:NULL];
        }
    }).finally(^{
        @strongify(self);
        self.articleFetcherPromise = nil;
        [self observeArticleUpdates];
        [self wmf_hideEmptyView];
    });
}

- (void)fetchReadMore {
    @weakify(self);
    [self.readMoreListViewController fetch].then(^(id readMoreResults) {
        @strongify(self);
        [self updateArticleFootersIfNeeded];
    })
    .catch(^(NSError* error){
        DDLogError(@"Read More Fetch Error: %@", error);
        WMF_TECH_DEBT_TODO(show error view in read more)
    });
}

#pragma mark - Scroll Position and Fragments

- (void)scrollWebViewToRequestedPosition {
    if (self.articleTitle.fragment) {
        [self.webViewController scrollToFragment:self.articleTitle.fragment];
    } else if (self.restoreScrollPositionOnArticleLoad && self.historyEntry.scrollPosition > 0) {
        self.restoreScrollPositionOnArticleLoad = NO;
        [self.webViewController scrollToVerticalOffset:self.historyEntry.scrollPosition];
    }
    [self markFragmentAsProcessed];
}

- (void)markFragmentAsProcessed {
    //Create a title without the fragment so it wont be followed anymore
    self.articleTitle = [[MWKTitle alloc] initWithSite:self.articleTitle.site normalizedTitle:self.articleTitle.text fragment:nil];
}

#pragma mark - WebView Transition

- (void)showWebViewAtFragment:(NSString*)fragment animated:(BOOL)animated {
    [self.webViewController scrollToFragment:fragment];
}

#pragma mark - WMFWebViewControllerDelegate

- (void)         webViewController:(WebViewController*)controller
    didTapImageWithSourceURLString:(nonnull NSString*)imageSourceURLString {
    MWKImage* selectedImage = [[MWKImage alloc] initWithArticle:self.article sourceURLString:imageSourceURLString];
    /*
       NOTE(bgerstle): not setting gallery delegate intentionally to prevent header gallery changes as a result of
       fullscreen gallery interactions that originate from the webview
     */
    WMFModalImageGalleryViewController* fullscreenGallery =
        [[WMFModalImageGalleryViewController alloc] initWithImagesInArticle:self.article
                                                               currentImage:selectedImage];
    [self presentViewController:fullscreenGallery animated:YES completion:nil];
}

- (void)webViewController:(WebViewController*)controller didLoadArticle:(MWKArticle*)article {
    [self scrollWebViewToRequestedPosition];
    [self.delegate articleControllerDidLoadArticle:self];
}

- (void)webViewController:(WebViewController*)controller didTapEditForSection:(MWKSection*)section {
    [self showEditorForSection:section];
}

- (void)webViewController:(WebViewController*)controller didTapOnLinkForTitle:(MWKTitle*)title {
    WMFArticleViewController* vc = [[WMFArticleViewController alloc] initWithArticleTitle:title dataStore:self.dataStore];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)webViewController:(WebViewController*)controller didSelectText:(NSString*)text {
    [self.shareFunnel logHighlight];
}

- (void)webViewController:(WebViewController*)controller didTapShareWithSelectedText:(NSString*)text {
    [self.delegate articleControllerDidTapShareSelectedText:self];
}

- (nullable NSString*)webViewController:(WebViewController*)controller titleForFooterViewController:(UIViewController*)footerViewController {
    if (footerViewController == self.readMoreListViewController) {
        return [MWSiteLocalizedString(self.articleTitle.site, @"article-read-more-title", nil) uppercaseStringWithLocale:[NSLocale currentLocale]];
    } else if (footerViewController == self.footerMenuViewController) {
        return [MWSiteLocalizedString(self.articleTitle.site, @"article-about-title", nil) uppercaseStringWithLocale:[NSLocale currentLocale]];
    }
    return nil;
}

#pragma mark - WMFArticleHeadermageGalleryViewControllerDelegate

- (void)headerImageGallery:(WMFArticleHeaderImageGalleryViewController* __nonnull)gallery
     didSelectImageAtIndex:(NSUInteger)index {
    WMFModalImageGalleryViewController* fullscreenGallery;

    if (self.article.isCached) {
        fullscreenGallery = [[WMFModalImageGalleryViewController alloc] initWithImagesInArticle:self.article
                                                                                   currentImage:nil];
        fullscreenGallery.currentPage = gallery.currentPage;
    } else {
        /*
           In case the user taps on the lead image before the article is loaded, present the gallery w/ the lead image
           as a placeholder, then populate it in-place once the article is fetched.
         */
        NSAssert(index == 0, @"Unexpected selected index for uncached article. Only expecting lead image tap.");
        if (!self.articleFetcherPromise) {
            // Fetch the article if it hasn't been fetched already
            DDLogInfo(@"User tapped lead image before article fetch started, fetching before showing gallery.");
            [self fetchArticleIfNeeded];
        }
        fullscreenGallery =
            [[WMFModalImageGalleryViewController alloc] initWithImagesInFutureArticle:self.articleFetcherPromise
                                                                          placeholder:self.article];
    }

    // set delegate to ensure the header gallery is updated when the fullscreen gallery is dismissed
    fullscreenGallery.delegate = self;

    [self presentViewController:fullscreenGallery animated:YES completion:nil];
}

#pragma mark - WMFModalArticleImageGalleryViewControllerDelegate

- (void)willDismissGalleryController:(WMFModalImageGalleryViewController* __nonnull)gallery {
    self.headerGallery.currentPage = gallery.currentPage;
}

#pragma mark - Edit Section

- (void)showEditorForSection:(MWKSection*)section {
    if (self.article.editable) {
        SectionEditorViewController* sectionEditVC = [SectionEditorViewController wmf_initialViewControllerFromClassStoryboard];
        sectionEditVC.section  = section;
        sectionEditVC.delegate = self;
        [self.navigationController pushViewController:sectionEditVC animated:YES];
    } else {
        ProtectedEditAttemptFunnel* funnel = [[ProtectedEditAttemptFunnel alloc] init];
        [funnel logProtectionStatus:[[self.article.protection allowedGroupsForAction:@"edit"] componentsJoinedByString:@","]];
        [self showProtectedDialog];
    }
}

- (void)showProtectedDialog {
    UIAlertView* alert = [[UIAlertView alloc] init];
    alert.title   = MWLocalizedString(@"page_protected_can_not_edit_title", nil);
    alert.message = MWLocalizedString(@"page_protected_can_not_edit", nil);
    [alert addButtonWithTitle:@"OK"];
    alert.cancelButtonIndex = 0;
    [alert show];
}

#pragma mark - SectionEditorViewControllerDelegate

- (void)sectionEditorFinishedEditing:(SectionEditorViewController*)sectionEditorViewController {
    [self.navigationController popToViewController:self animated:YES];
    [self fetchArticleIfNeeded];
}

#pragma mark - UIViewControllerPreviewingDelegate

- (void)registerForPreviewingIfAvailable {
    [self wmf_ifForceTouchAvailable:^{
        [self unregisterForPreviewing];
        UIView* previewView = [self.webViewController.webView wmf_browserView];
        self.linkPreviewingContext =
            [self registerForPreviewingWithDelegate:self sourceView:previewView];
        for (UIGestureRecognizer* r in previewView.gestureRecognizers) {
            [r requireGestureRecognizerToFail:self.linkPreviewingContext.previewingGestureRecognizerForFailureRelationship];
        }
    } unavailable:^{
        [self unregisterForPreviewing];
    }];
}

- (void)unregisterForPreviewing {
    if (self.linkPreviewingContext) {
        [self unregisterForPreviewingWithContext:self.linkPreviewingContext];
        self.linkPreviewingContext = nil;
    }
}

- (nullable UIViewController*)previewingContext:(id<UIViewControllerPreviewing>)previewingContext
                      viewControllerForLocation:(CGPoint)location {
    JSValue* peekElement = [self.webViewController htmlElementAtLocation:location];
    if (!peekElement) {
        return nil;
    }

    NSURL* peekURL = [self.webViewController urlForHTMLElement:peekElement];
    if (!peekURL) {
        return nil;
    }

    UIViewController* peekVC = [self viewControllerForPreviewURL:peekURL];
    if (peekVC) {
        [[PiwikTracker sharedInstance] wmf_logActionPreviewFromSource:self];
        self.isPreviewing                = YES;
        self.webViewController.isPeeking = YES;
        previewingContext.sourceRect     = [self.webViewController rectForHTMLElement:peekElement];
        return peekVC;
    }

    return nil;
}

- (UIViewController*)viewControllerForPreviewURL:(NSURL*)url {
    if ([url.absoluteString isEqualToString:@""]) {
        return nil;
    }
    if (![url wmf_isInternalLink]) {
        if ([url wmf_isCitation]) {
            return nil;
        }
        return [[SFSafariViewController alloc] initWithURL:url];
    } else {
        if (![url wmf_isIntraPageFragment]) {
            return [[WMFArticleViewController alloc] initWithArticleTitle:[[MWKTitle alloc] initWithURL:url]
                                                                dataStore:self.dataStore];
        }
    }
    return nil;
}

- (void)previewingContext:(id<UIViewControllerPreviewing>)previewingContext
     commitViewController:(UIViewController*)viewControllerToCommit {
    [[PiwikTracker sharedInstance] wmf_logActionPreviewCommittedFromSource:self];
    self.isPreviewing = NO;
    if ([viewControllerToCommit isKindOfClass:[WMFArticleViewController class]]) {
        [self pushArticleViewController:(WMFArticleViewController*)viewControllerToCommit animated:YES];
    } else {
        [self presentViewController:viewControllerToCommit animated:YES completion:nil];
    }
}

#pragma mark - Article Navigation


- (void)pushArticleViewController:(WMFArticleViewController*)articleViewController animated:(BOOL)animated {
    //Delay this so any visual updates to lists are postponed until the article after the article is displayed
    //Some lists (like history) will show these artifacts as the push navigation is occuring.
    dispatchOnMainQueueAfterDelayInSeconds(0.5, ^{
        MWKHistoryList* historyList = articleViewController.dataStore.userDataStore.historyList;
        [historyList addPageToHistoryWithTitle:articleViewController.articleTitle];
        [historyList save];
    });
}

- (void)pushArticleViewControllerWithTitle:(MWKTitle*)title animated:(BOOL)animated {
    WMFArticleViewController* articleViewController =
        [[WMFArticleViewController alloc] initWithArticleTitle:title
                                                     dataStore:self.dataStore];
    [self pushArticleViewController:articleViewController animated:animated];
}

#pragma mark - WMFAnalyticsLogging


- (NSString*)analyticsName {
    return @"Article";
}

@end

NS_ASSUME_NONNULL_END
