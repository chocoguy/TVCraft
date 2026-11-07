// Worlds that outlast tvOS's cache purges (TVSaves.mm).
#import <Foundation/Foundation.h>

NSString *tv_saves_root(void);   // Library/Caches/games/com.mojang, where the game keeps its worlds and options
void tv_saves_restore(void);     // at launch, before the game reads its folders: bring back what tvOS purged
void tv_saves_sync(BOOL leaving); // after the game saved: copy what changed into the preferences. leaving: the app is going to the background
