//
//  MP42SubtitleTrack.h
//  Subler
//
//  Created by Damiano Galassi on 31/01/09.
//  Copyright 2009 Damiano Galassi. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "mp4v2.h"
#import <QTKit/QTKit.h>

typedef struct framerate_t {
    uint32_t code;
    uint32_t timescale;
    uint32_t duration;
} framerate_t;

int muxH264ElementaryStream(MP4FileHandle fileHandle, NSString* filePath, uint32_t frameRateCode);

#if !__LP64__
    int muxMOVVideoTrack(MP4FileHandle fileHandle, QTMovie* srcFile, MP4TrackId srcTrackId);
#endif
    
int muxMP4VideoTrack(MP4FileHandle fileHandle, NSString* filePath, MP4TrackId srcTrackId);
int muxMKVVideoTrack(MP4FileHandle fileHandle, NSString* filePath, MP4TrackId srcTrackId);

