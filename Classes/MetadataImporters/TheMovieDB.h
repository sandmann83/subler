//
//  themoviedb.h
//  Subler
//
//  Created by Douglas Stebila on 2011/01/28.
//  Copyright 2011 Douglas Stebila. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@class MetadataSearchController;
@class MP42Metadata;

@interface TheMovieDB : NSObject {
    NSString *mMovieTitle;
	NSString *mMovieLanguage;
    MP42Metadata *mMetadata;
    MetadataSearchController *mCallback;
    BOOL isCancelled;
}

- (NSArray*) searchForResults:(NSString *)movieTitle mMovieLanguage:(NSString *)aMovieLanguage;
- (void) searchForResults:(NSString *)movieTitle mMovieLanguage:(NSString *)aMovieLanguage callback:(MetadataSearchController *)callback;

- (MP42Metadata*) loadAdditionalMetadata:(MP42Metadata *)metadata mMovieLanguage:(NSString *)aMovieLanguage;
- (void) loadAdditionalMetadata:(MP42Metadata *)metadata mMovieLanguage:(NSString *)aMovieLanguage callback:(MetadataSearchController *)callback;

- (void) cancel;

@end
