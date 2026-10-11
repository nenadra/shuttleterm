//
//  AppDelegate.h
//  ShuttleTerm
//

#import <Cocoa/Cocoa.h>
#import "LaunchAtLoginController.h"

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>{
    IBOutlet NSMenu *menu;

    NSImage *regularIcon;

    NSStatusItem *statusItem;
    NSString *shuttleConfigFile;

    NSDate *configModified;

    NSString *shuttleJSONPathPref;
    NSString *themePref;
    NSString *fontPref;

    NSMutableArray *startupHostItems;
    BOOL didLaunchStartupHosts;
    BOOL focusOnHoverPref;
    BOOL titlebarOnHoverPref;
    BOOL reconnectPref;

    NSString *menuName;
    BOOL addSeparator;

    NSMutableArray* shuttleHosts;

    LaunchAtLoginController *launchAtLoginController;

}

- (void)menuWillOpen:(NSMenu *)menu;
- (NSString *)configurationFilePath;
- (void)ensureConfigurationFile;
- (void)reloadFromJSON;
- (IBAction)showSettings:(id)sender;
- (IBAction)showAbout:(id)sender;

@end
