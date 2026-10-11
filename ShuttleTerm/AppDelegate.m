//
//  AppDelegate.m
//  ShuttleTerm
//

#import "AppDelegate.h"
#import "ShuttleTerm-Swift.h"

@implementation AppDelegate

+ (void)initialize {
    if (self == [AppDelegate class]) {
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{
            @"NSMenuEnableActionImages": @NO
        }];
    }
}

- (BOOL)isOpenableURL:(NSString *)command {
    NSString *trimmed = [command stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSURL *url = [NSURL URLWithString:trimmed];
    NSString *scheme = url.scheme.lowercaseString;
    return [scheme isEqualToString:@"http"] ||
           [scheme isEqualToString:@"https"] ||
           [scheme isEqualToString:@"mailto"] ||
           [scheme isEqualToString:@"ftp"];
}

- (void) awakeFromNib {
    shuttleJSONPathPref = [NSHomeDirectory() stringByAppendingPathComponent:@".shuttleterm.path"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:shuttleJSONPathPref]) {
        NSString *jsonConfigPath = [NSString stringWithContentsOfFile:shuttleJSONPathPref encoding:NSUTF8StringEncoding error:NULL];
        jsonConfigPath = [jsonConfigPath stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        shuttleConfigFile = jsonConfigPath;
    } else {
        shuttleConfigFile = [NSHomeDirectory() stringByAppendingPathComponent:@".shuttleterm.json"];
    }
    [self ensureConfigurationFile];
    [ShuttleSettingsPanel migrateConfigIfNeeded];

    regularIcon = [NSImage imageNamed:@"StatusIcon"];
    regularIcon.template = YES;
    statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    [statusItem setMenu:menu];
    [statusItem setImage:regularIcon];

    launchAtLoginController = [[LaunchAtLoginController alloc] init];
    [menu setDelegate:self];
    didLaunchStartupHosts = NO;
    startupHostItems = [NSMutableArray array];

    configModified = [self getMTimeFor:shuttleConfigFile];
    [self installSettingsToggles];
    [self restyleApplicationMenu];
    [self loadMenu];
    [self hideAutomaticMenuImages:menu];
    [self openStartupHostsIfNeeded];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    if ([[[NSProcessInfo processInfo] arguments] containsObject:@"--self-test-terminal"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[ShuttleTerminalController shared] openHostConfig:@{
                @"cmd": @"printf 'shuttleterm-ok\\n'; exec sleep 8",
                @"title": @"ShuttleTerm Test",
                @"name": @"ShuttleTerm Test",
                @"theme": @"Homebrew"
            }];
        });
    }
}

- (BOOL) needUpdateFor: (NSString*) file with: (NSDate*) old {

    if (![[NSFileManager defaultManager] fileExistsAtPath:[file stringByExpandingTildeInPath]])
        return false;

    if (old == NULL)
        return true;

    NSDate *date = [self getMTimeFor:file];
    return [date compare: old] == NSOrderedDescending;
}

- (NSDate*) getMTimeFor: (NSString*) file {
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:[file stringByExpandingTildeInPath]
                                                                                error:nil];
    return [attributes fileModificationDate];
}

- (void)menuWillOpen:(NSMenu *)menu {
    if ([self needUpdateFor:shuttleConfigFile with:configModified]) {
        configModified = [self getMTimeFor:shuttleConfigFile];
        [self loadMenu];
    }
    [self hideAutomaticMenuImages:menu];
    [[ShuttleTerminalController shared] refreshSplitMenus];
}

- (void) loadMenu {
    NSUInteger n = [[menu itemArray] count];
    for (int i=0;i<n-4;i++) {
        [menu removeItemAtIndex:0];
    }

    [self ensureConfigurationFile];
    NSData *data = [NSData dataWithContentsOfFile:shuttleConfigFile];
    id json = [NSJSONSerialization JSONObjectWithData:data
                                              options:NSJSONReadingMutableContainers
                                                error:nil];
    if ( !json ) {
        NSMenuItem *menuItem = [menu insertItemWithTitle:NSLocalizedString(@"Error parsing config",nil)
                                                  action:false
                                           keyEquivalent:@""
                                                 atIndex:0
                                ];
        [menuItem setEnabled:false];
        [self insertTerminalActionsIntoMenu];
        [self syncHostsToFileMenu:@[]];
        return;
    }

    startupHostItems = [NSMutableArray array];
    themePref = json[@"default_theme"];
    fontPref = json[@"default_font"];
    launchAtLoginController.launchAtLogin = [json[@"launch_at_login"] boolValue];
    if ([[json allKeys] containsObject:@"focus_on_hover"]) {
        focusOnHoverPref = [json[@"focus_on_hover"] boolValue];
    } else {
        focusOnHoverPref = NO;
    }
    if ([[json allKeys] containsObject:@"titlebar"]) {
        titlebarOnHoverPref = ![[json[@"titlebar"] lowercaseString] isEqualToString:@"always"];
    } else {
        titlebarOnHoverPref = YES;
    }
    if ([[json allKeys] containsObject:@"reconnect"]) {
        reconnectPref = [json[@"reconnect"] boolValue];
    } else {
        reconnectPref = YES;
    }
    BOOL restoreWindowsPref = YES;
    if ([[json allKeys] containsObject:@"restore_windows"]) {
        restoreWindowsPref = [json[@"restore_windows"] boolValue];
    }
    [ShuttleTerminalController shared].focusOnHover = focusOnHoverPref;
    [ShuttleTerminalController shared].titlebarOnHover = titlebarOnHoverPref;
    [ShuttleTerminalController shared].reconnectRemote = reconnectPref;
    [ShuttleTerminalController shared].restoreWindows = restoreWindowsPref;
    BOOL lockAfterSleep = NO;
    if ([[json allKeys] containsObject:@"lock_after_sleep"]) {
        lockAfterSleep = [json[@"lock_after_sleep"] boolValue];
    }
    [ShuttleAppLock shared].isEnabled = lockAfterSleep;
    NSString *alignGrid = [json[@"align_grid"] lowercaseString];
    [ShuttleTerminalController shared].alignGrid = [alignGrid isEqualToString:@"4x3"] ? @"4x3" : @"5x4";
    [self refreshSettingsToggles];
    shuttleHosts = json[@"hosts"];

    [self buildMenu:shuttleHosts addToMenu:menu];
    [self insertTerminalActionsIntoMenu];
    [self syncHostsToFileMenu:shuttleHosts];
}

- (void) buildMenu:(NSArray*)data addToMenu:(NSMenu *)m {
    NSMutableDictionary* menus = [[NSMutableDictionary alloc] init];
    NSMutableDictionary* leafs = [[NSMutableDictionary alloc] init];

    for (NSDictionary* item in data) {
        if (item[@"cmd"] && item[@"name"]) {
            [leafs setObject:item forKey:item[@"name"]];
        } else {
            for (NSString* key in item) {
                [menus setObject:item[key] forKey:key];
            }
        }
    }

    NSArray* menuKeys = [[menus allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSArray* leafKeys = [[leafs allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

    NSInteger pos = 0;

    for (NSString* key in menuKeys) {
        NSMenu* subMenu = [[NSMenu alloc] init];
        NSMenuItem* menuItem = [[NSMenuItem alloc] init];
        [self separatorSortRemoval:key];
        [menuItem setTitle:menuName];
        [menuItem setSubmenu:subMenu];
        [m insertItem:menuItem atIndex:pos++];
        if (addSeparator) {
            [m insertItem:[NSMenuItem separatorItem] atIndex:pos++];
        }
        [self buildMenu:menus[key] addToMenu:subMenu];
    }

    for (NSString *key in leafKeys) {
        NSDictionary* cfg = leafs[key];
        NSMenuItem* menuItem = [[NSMenuItem alloc] init];

        NSString *menuCmd = cfg[@"cmd"];
        NSString *termTheme = cfg[@"theme"];
        NSString *termTitle = cfg[@"title"];
        [self separatorSortRemoval:cfg[@"name"]];

        NSMutableDictionary *menuRepObj = [NSMutableDictionary dictionary];
        if (menuCmd) { menuRepObj[@"cmd"] = menuCmd; }
        if (termTheme) { menuRepObj[@"theme"] = termTheme; }
        if (termTitle) { menuRepObj[@"title"] = termTitle; }
        if (menuName) { menuRepObj[@"name"] = menuName; }
        if ([cfg[@"after"] isKindOfClass:[NSString class]]) {
            menuRepObj[@"after"] = cfg[@"after"];
        }
        if ([cfg[@"font"] isKindOfClass:[NSString class]]) {
            menuRepObj[@"font"] = cfg[@"font"];
        }
        BOOL startup = [cfg[@"startup"] boolValue];
        menuRepObj[@"startup"] = @(startup);
        if (cfg[@"reconnect"] != nil) {
            menuRepObj[@"reconnect"] = cfg[@"reconnect"];
        }

        [menuItem setTitle:menuName];
        [menuItem setRepresentedObject:menuRepObj];
        [menuItem setAction:@selector(openHost:)];
        if (startup) {
            [menuItem setState:NSControlStateValueOn];
            [menuItem setToolTip:NSLocalizedString(@"Opens automatically when ShuttleTerm starts", nil)];
            [startupHostItems addObject:menuRepObj];
        }
        [m insertItem:menuItem atIndex:pos++];
        if (addSeparator) {
            [m insertItem:[NSMenuItem separatorItem] atIndex:pos++];
        }
    }
}

- (void) separatorSortRemoval:(NSString *)currentName {
    NSError *regexError = nil;
    addSeparator = NO;

    NSRegularExpression *regexSort = [NSRegularExpression regularExpressionWithPattern:@"([\\[][a-z]{3}[\\]])" options:0 error:&regexError];
    NSRegularExpression *regexSeparator = [NSRegularExpression regularExpressionWithPattern:@"([\\[][-]{3}[\\]])" options:0 error:&regexError];

    NSUInteger sortMatches = [regexSort numberOfMatchesInString:currentName options:0 range:NSMakeRange(0,[currentName length])];
    NSUInteger separatorMatches = [regexSeparator  numberOfMatchesInString:currentName options:0 range:NSMakeRange(0,[currentName length])];

    if ( sortMatches == 1 || separatorMatches == 1 ) {
        if (sortMatches == 1 && separatorMatches == 1 ) {
            menuName = [regexSort stringByReplacingMatchesInString:currentName options:0 range:NSMakeRange(0, [currentName length]) withTemplate:@""];
            menuName = [regexSeparator stringByReplacingMatchesInString:menuName options:0 range:NSMakeRange(0, [menuName length]) withTemplate:@""];
            addSeparator = YES;
        } else {

            if( sortMatches == 1) {
                menuName = [regexSort stringByReplacingMatchesInString:currentName options:0 range:NSMakeRange(0, [currentName length]) withTemplate:@""];
                addSeparator = NO;
            }
            if ( separatorMatches == 1 ) {
                menuName = [regexSeparator stringByReplacingMatchesInString:currentName options:0 range:NSMakeRange(0, [currentName length]) withTemplate:@""];
                addSeparator = YES;
            }
        }
    } else {
        menuName = currentName;
        addSeparator = NO;
    }
}

- (NSString *)stringFromJSONValue:(id)value {
    if ([value isKindOfClass:[NSString class]] && [value length] > 0 && ![value isEqualToString:@"(null)"]) {
        return value;
    }
    return nil;
}

- (void) insertTerminalActionsIntoMenu {
    NSInteger insertAt = MAX(0, (NSInteger)[[menu itemArray] count] - 4);
    [menu insertItem:[NSMenuItem separatorItem] atIndex:insertAt++];

    NSMenuItem *run = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Run Command…", nil)
                                                 action:@selector(promptAndRunCommand:)
                                          keyEquivalent:@""];
    run.target = [ShuttleTerminalController shared];
    [menu insertItem:run atIndex:insertAt++];

    NSMenu *splitMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Split", nil)];
    [[ShuttleTerminalController shared] attachMenubarSplitMenu:splitMenu];
    NSMenuItem *splitRoot = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Split", nil)
                                                      action:nil
                                               keyEquivalent:@""];
    splitRoot.submenu = splitMenu;
    splitRoot.tag = 9010;
    [menu insertItem:splitRoot atIndex:insertAt++];

    NSMenu *alignMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Align", nil)];
    [[ShuttleTerminalController shared] attachMenubarAlignMenu:alignMenu];
    NSMenuItem *alignRoot = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Align", nil)
                                                      action:nil
                                               keyEquivalent:@""];
    alignRoot.submenu = alignMenu;
    alignRoot.tag = 9011;
    [menu insertItem:alignRoot atIndex:insertAt];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    ShuttleAttention *attention = [ShuttleAttention shared];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [attention prepare];
    });
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [[ShuttleTerminalController shared] persistOpenWindows];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    [[ShuttleTerminalController shared] restackWindowsOnActiveSpace];
}

- (void)applicationDidResignActive:(NSNotification *)notification {
    [[ShuttleTerminalController shared] persistOpenWindows];
}

- (void) openStartupHostsIfNeeded {
    if (didLaunchStartupHosts) {
        return;
    }
    didLaunchStartupHosts = YES;
    if ([[[NSProcessInfo processInfo] arguments] containsObject:@"--self-test-terminal"]) {
        return;
    }
    if ([[ShuttleTerminalController shared] restoreSavedWindowsIfEnabled]) {
        return;
    }
    if ([startupHostItems count] == 0) {
        return;
    }
    NSArray *hosts = [startupHostItems copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        for (NSDictionary *cfg in hosts) {
            NSMenuItem *item = [[NSMenuItem alloc] init];
            [item setRepresentedObject:cfg];
            [self openHost:item];
        }
        if ([hosts count] >= 2) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[ShuttleTerminalController shared] splitIntoGridWithCount:(int)[hosts count]];
            });
        }
    });
}

- (void) openHost:(NSMenuItem *) sender {
    NSString *escapedObject;
    NSString *terminalTheme;
    NSString *terminalTitle;
    NSString *afterCommand = nil;
    NSString *fontName = nil;
    NSString *savedName = nil;

    id represented = [sender representedObject];
    if ([represented isKindOfClass:[NSDictionary class]]) {
        NSDictionary *cfg = (NSDictionary *)represented;
        escapedObject = [self stringFromJSONValue:cfg[@"cmd"]] ?: @"";
        terminalTheme = [self stringFromJSONValue:cfg[@"theme"]];
        terminalTitle = [self stringFromJSONValue:cfg[@"title"]];
        afterCommand = [self stringFromJSONValue:cfg[@"after"]];
        fontName = [self stringFromJSONValue:cfg[@"font"]];
        savedName = [self stringFromJSONValue:cfg[@"name"]];
    } else {
        NSArray *objectsFromJSON = [[sender representedObject] componentsSeparatedByString:(@"¬_¬")];
        escapedObject = [objectsFromJSON objectAtIndex:0];
        if ([objectsFromJSON count] > 1) {
            terminalTheme = [self stringFromJSONValue:[objectsFromJSON objectAtIndex:1]];
        }
        if ([objectsFromJSON count] > 2) {
            terminalTitle = [self stringFromJSONValue:[objectsFromJSON objectAtIndex:2]];
        }
        if ([objectsFromJSON count] > 4) {
            savedName = [self stringFromJSONValue:[objectsFromJSON objectAtIndex:4]];
        }
    }

    if (terminalTheme == nil) {
        terminalTheme = themePref ?: @"Pro";
    }

    if (fontName == nil && fontPref != nil && fontPref != 0) {
        fontName = fontPref;
    }

    if( terminalTitle == nil ){
        terminalTitle = savedName ?: [sender title] ?: @"ShuttleTerm";
    }

    if ([self isOpenableURL:escapedObject]) {
        NSURL *url = [NSURL URLWithString:escapedObject];
        NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
        config.activates = YES;
        [[NSWorkspace sharedWorkspace] openURL:url configuration:config completionHandler:nil];
        return;
    }

    NSMutableDictionary *hostConfig = [NSMutableDictionary dictionary];
    NSString *headerName = savedName ?: terminalTitle ?: @"ShuttleTerm";
    hostConfig[@"cmd"] = escapedObject ?: @"";
    hostConfig[@"title"] = headerName;
    hostConfig[@"name"] = headerName;
    hostConfig[@"theme"] = terminalTheme ?: @"Pro";
    if (afterCommand.length > 0) {
        hostConfig[@"after"] = afterCommand;
    }
    if (fontName.length > 0) {
        hostConfig[@"font"] = fontName;
    }
    if ([represented isKindOfClass:[NSDictionary class]] && ((NSDictionary *)represented)[@"reconnect"] != nil) {
        hostConfig[@"reconnect"] = ((NSDictionary *)represented)[@"reconnect"];
    }
    [[ShuttleTerminalController shared] openHostConfig:hostConfig];
}

- (void) restyleApplicationMenu {
    NSMenu *mainMenu = [NSApp mainMenu];
    if ([mainMenu numberOfItems] > 0) {
        NSMenuItem *appRoot = [mainMenu itemAtIndex:0];
        [appRoot setTitle:@"ShuttleTerm"];
        NSMenu *appMenu = [appRoot submenu];
        [appMenu setTitle:@"ShuttleTerm"];
        for (NSMenuItem *item in [appMenu itemArray]) {
            if ([[item title] containsString:@"Quit"]) {
                [item setTitle:@"Quit ShuttleTerm"];
            }
        }
        NSMenuItem *about = nil;
        for (NSMenuItem *item in [appMenu itemArray]) {
            NSString *title = [item title];
            if ([title localizedCaseInsensitiveContainsString:@"About"] ||
                [title localizedCaseInsensitiveContainsString:@"Help"]) {
                about = item;
                break;
            }
        }
        if (about == nil) {
            about = [[NSMenuItem alloc] initWithTitle:@"About ShuttleTerm"
                                               action:@selector(showAbout:)
                                        keyEquivalent:@""];
            [appMenu insertItem:about atIndex:0];
            if ([appMenu numberOfItems] > 1 && ![[appMenu itemAtIndex:1] isSeparatorItem]) {
                [appMenu insertItem:[NSMenuItem separatorItem] atIndex:1];
            }
        }
        [about setTitle:@"About ShuttleTerm"];
        [about setAction:@selector(showAbout:)];
        [about setTarget:self];
        [about setKeyEquivalent:@""];
        NSMenuItem *settings = nil;
        for (NSMenuItem *item in [appMenu itemArray]) {
            NSString *title = [item title];
            if ([title localizedCaseInsensitiveContainsString:@"Settings"] ||
                [title localizedCaseInsensitiveContainsString:@"Preferences"]) {
                settings = item;
                break;
            }
        }
        if (settings == nil) {
            settings = [[NSMenuItem alloc] initWithTitle:@"Settings…"
                                                  action:@selector(showSettings:)
                                           keyEquivalent:@","];
            settings.target = self;
            NSInteger idx = 1;
            if ([appMenu numberOfItems] > 1 && [[appMenu itemAtIndex:1] isSeparatorItem]) {
                idx = 2;
            }
            [appMenu insertItem:settings atIndex:MIN(idx, [appMenu numberOfItems])];
            NSInteger after = MIN(idx + 1, [appMenu numberOfItems]);
            if (after >= [appMenu numberOfItems] || ![[appMenu itemAtIndex:after] isSeparatorItem]) {
                [appMenu insertItem:[NSMenuItem separatorItem] atIndex:after];
            }
        } else {
            settings.submenu = nil;
            settings.action = @selector(showSettings:);
            settings.target = self;
            settings.keyEquivalent = @",";
        }
    }
    [[ShuttleTerminalController shared] ensureAppMenus];
    [self hideAutomaticMenuImages:[NSApp mainMenu]];
}

- (void)syncHostsToFileMenu:(NSArray *)hosts {
    NSMenu *mainMenu = [NSApp mainMenu];
    if (mainMenu == nil) {
        return;
    }
    [[ShuttleTerminalController shared] ensureAppMenus];

    for (NSMenuItem *item in [[mainMenu itemArray] copy]) {
        if (item.tag == 9020 || [[item title] isEqualToString:@"Hosts"]) {
            [mainMenu removeItem:item];
        }
    }

    NSMenu *fileMenu = nil;
    for (NSMenuItem *item in [mainMenu itemArray]) {
        if ([[item title] isEqualToString:@"File"]) {
            fileMenu = item.submenu;
            break;
        }
    }
    if (fileMenu == nil) {
        return;
    }

    for (NSMenuItem *item in [[fileMenu itemArray] copy]) {
        if (item.tag == 9021) {
            [fileMenu removeItem:item];
        }
    }

    if ([hosts count] == 0) {
        [self hideAutomaticMenuImages:fileMenu];
        return;
    }

    NSMutableArray *hostItems = [NSMutableArray array];
    for (NSMenuItem *item in [menu itemArray]) {
        NSString *title = [item title];
        if ([title isEqualToString:@"Run Command…"] ||
            [title isEqualToString:@"Split"] ||
            [title isEqualToString:@"Align"] ||
            [title isEqualToString:@"Settings"] ||
            [title isEqualToString:@"Settings…"] ||
            [title isEqualToString:@"Help"] ||
            [title isEqualToString:@"About ShuttleTerm"] ||
            [title hasPrefix:@"Quit"]) {
            break;
        }
        [hostItems addObject:item];
    }
    while ([hostItems count] > 0 && [[hostItems lastObject] isSeparatorItem]) {
        [hostItems removeLastObject];
    }
    if ([hostItems count] == 0) {
        [self hideAutomaticMenuImages:fileMenu];
        return;
    }

    NSMenuItem *sep = [NSMenuItem separatorItem];
    sep.tag = 9021;
    [fileMenu addItem:sep];
    for (NSMenuItem *item in hostItems) {
        NSMenuItem *copy = [item copy];
        copy.tag = 9021;
        [fileMenu addItem:copy];
    }
    [self hideAutomaticMenuImages:fileMenu];
}

- (void) installSettingsToggles {
    NSMenuItem *settingsItem = nil;
    for (NSMenuItem *item in [menu itemArray]) {
        if ([[item title] isEqualToString:@"Settings"]) {
            settingsItem = item;
            break;
        }
    }
    if (settingsItem == nil) {
        return;
    }
    settingsItem.submenu = nil;
    settingsItem.action = @selector(showSettings:);
    settingsItem.target = self;
    settingsItem.keyEquivalent = @"";
    [self hideAutomaticMenuImages:menu];
}

- (void)hideAutomaticMenuImages:(NSMenu *)theMenu {
    if (theMenu == nil) { return; }
    for (NSMenuItem *item in [theMenu itemArray]) {
        if (!item.isSeparatorItem) {
            NSImage *dummy = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
            item.image = dummy;
            item.image = nil;
            item.attributedTitle = nil;
            if (@available(macOS 27.0, *)) {
                item.preferredImageVisibility = NSMenuItemImageVisibilityHidden;
            }
        }
        if (item.submenu != nil) {
            [self hideAutomaticMenuImages:item.submenu];
        }
    }
}

- (void) refreshSettingsToggles {
}

- (void) writeJSONKey:(NSString *)key value:(id)value {
    NSData *data = [NSData dataWithContentsOfFile:shuttleConfigFile];
    if (data == nil) { return; }
    NSMutableDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if (![json isKindOfClass:[NSMutableDictionary class]]) { return; }
    json[key] = value;
    NSData *out = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil];
    [out writeToFile:shuttleConfigFile atomically:YES];
    configModified = [self getMTimeFor:shuttleConfigFile];
}

- (NSString *)configurationFilePath {
    return shuttleConfigFile;
}

- (void)ensureConfigurationFile {
    if (shuttleConfigFile.length == 0) {
        shuttleConfigFile = [NSHomeDirectory() stringByAppendingPathComponent:@".shuttleterm.json"];
    }
    NSFileManager *files = [NSFileManager defaultManager];
    if ([files fileExistsAtPath:shuttleConfigFile]) {
        return;
    }
    NSString *bundled = [[NSBundle mainBundle] pathForResource:@"shuttleterm.default" ofType:@"json"];
    if (bundled != nil) {
        [files copyItemAtPath:bundled toPath:shuttleConfigFile error:nil];
    }
    if (![files fileExistsAtPath:shuttleConfigFile]) {
        NSDictionary *skeleton = @{
            @"launch_at_login": @NO,
            @"default_theme": @"Homebrew",
            @"default_font": @"Menlo",
            @"titlebar": @"hover",
            @"focus_on_hover": @NO,
            @"reconnect": @YES,
            @"restore_windows": @YES,
            @"lock_after_sleep": @NO,
            @"align_grid": @"5x4",
            @"hosts": @[]
        };
        NSData *data = [NSJSONSerialization dataWithJSONObject:skeleton options:NSJSONWritingPrettyPrinted error:nil];
        [data writeToFile:shuttleConfigFile atomically:YES];
    }
}

- (void)reloadFromJSON {
    [self loadMenu];
}

- (IBAction)showSettings:(id)sender {
    [[ShuttleTerminalController shared] activateApplication];
    [[ShuttleSettingsPanel shared] show];
}

- (IBAction)showAbout:(id)sender {
    [[ShuttleAboutPanel shared] show];
}

- (IBAction)showHelp:(id)sender {
    [[ShuttleTerminalController shared] showHelp:sender];
}

- (IBAction)quit:(id)sender {
    [[NSStatusBar systemStatusBar] removeStatusItem:statusItem];
    [NSApp terminate:NSApp];
}

@end
