//
//  MP42Muxer.m
//  Subler
//
//  Created by Damiano Galassi on 30/06/10.
//  Copyright 2010 Damiano Galassi. All rights reserved.
//

#import "MP42Muxer.h"
#import "MP42File.h"
#import "MP42FileImporter.h"
#import "MP42Sample.h"
#import "SBAudioConverter.h"
#import "SBBitmapSubConverter.h"

@implementation MP42Muxer

- (id)init
{
    if ((self = [super init])) {
        workingTracks = [[NSMutableArray alloc] init];
    }
    return self;
}

- (id)initWithDelegate:(id)del
{
    if ((self = [super init])) {
        workingTracks = [[NSMutableArray alloc] init];
        delegate = del;
    }

    return self;
}

- (void)addTrack:(MP42Track*)track
{
    if (![track isMemberOfClass:[MP42ChapterTrack class]])
        [workingTracks addObject:track];
}

- (BOOL)prepareWork:(MP4FileHandle)fileHandle error:(NSError **)outError
{
    BOOL noErr = YES;

    for (MP42Track * track in workingTracks) {
        MP4TrackId dstTrackId = 0;
        NSData *magicCookie;
        NSInteger timeScale;

        if ([track trackImporterHelper]) {
            magicCookie = [[track trackImporterHelper] magicCookieForTrack:track];
            timeScale = [[track trackImporterHelper] timescaleForTrack:track];
        }
        else
            continue;

        if([track isMemberOfClass:[MP42AudioTrack class]] && track.needConversion) {
            track.format = @"AAC";
            SBAudioConverter *audioConverter = [[SBAudioConverter alloc] initWithTrack:(MP42AudioTrack*)track
                                                                        andMixdownType:[(MP42AudioTrack*)track mixdownType]
                                                                                 error:outError];

            if (audioConverter == nil)
                noErr = NO;

            track.trackConverterHelper = audioConverter;
        }
        if([track isMemberOfClass:[MP42SubtitleTrack class]] && ([track.format isEqualToString:@"VobSub"] || [track.format isEqualToString:@"PGS"]) && track.needConversion) {
            track.format = @"3GPP Text";
            SBBitmapSubConverter *subConverter = [[SBBitmapSubConverter alloc] initWithTrack:(MP42SubtitleTrack*)track
                                                                                       error:outError];

            if (subConverter == nil)
                noErr = NO;

            track.trackConverterHelper = subConverter;
        }
        else if([track isMemberOfClass:[MP42SubtitleTrack class]] && track.needConversion)
            track.format = @"3GPP Text";

        // H.264 video track
        if ([track isMemberOfClass:[MP42VideoTrack class]] && [track.format isEqualToString:@"H.264"]) {
            if ([magicCookie length] < sizeof(uint8_t) * 6)
                continue;

            NSSize size = [[track trackImporterHelper] sizeForTrack:track];

            uint8_t* avcCAtom = (uint8_t*)[magicCookie bytes];
            dstTrackId = MP4AddH264VideoTrack(fileHandle, timeScale,
                                              MP4_INVALID_DURATION,
                                              size.width, size.height,
                                              avcCAtom[1],  // AVCProfileIndication
                                              avcCAtom[2],  // profile_compat
                                              avcCAtom[3],  // AVCLevelIndication
                                              avcCAtom[4]); // lengthSizeMinusOne

            SInt64 i;
            int8_t spsCount = (avcCAtom[5] & 0x1f);
            uint8_t ptrPos = 6;
            for (i = 0; i < spsCount; i++) {
                uint16_t spsSize = (avcCAtom[ptrPos++] << 8) & 0xff00;
                spsSize += avcCAtom[ptrPos++] & 0xff;
                MP4AddH264SequenceParameterSet(fileHandle, dstTrackId,
                                               avcCAtom+ptrPos, spsSize);
                ptrPos += spsSize;
            }

            int8_t ppsCount = avcCAtom[ptrPos++];
            for (i = 0; i < ppsCount; i++) {
                uint16_t ppsSize = (avcCAtom[ptrPos++] << 8) & 0xff00;
                ppsSize += avcCAtom[ptrPos++] & 0xff;
                MP4AddH264PictureParameterSet(fileHandle, dstTrackId,
                                              avcCAtom+ptrPos, ppsSize);
                ptrPos += ppsSize;
            }

            MP4SetVideoProfileLevel(fileHandle, 0x15);

            [[track trackImporterHelper] setActiveTrack:track];
        }

        // MPEG-4 Visual video track
        else if ([track isMemberOfClass:[MP42VideoTrack class]] && [track.format isEqualToString:@"MPEG-4 Visual"]) {
            MP4SetVideoProfileLevel(fileHandle, MPEG4_SP_L3);
            // Add video track
            dstTrackId = MP4AddVideoTrack(fileHandle, timeScale,
                                          MP4_INVALID_DURATION,
                                          [(MP42VideoTrack*)track width], [(MP42VideoTrack*)track height],
                                          MP4_MPEG4_VIDEO_TYPE);

            if ([magicCookie length])
                MP4SetTrackESConfiguration(fileHandle, dstTrackId,
                                           [magicCookie bytes],
                                           [magicCookie length]);

            [[track trackImporterHelper] setActiveTrack:track];
        }

        // Photo-JPEG video track
        else if ([track isMemberOfClass:[MP42VideoTrack class]] && [track.format isEqualToString:@"Photo - JPEG"]) {
            // Add video track
            dstTrackId = MP4AddJpegVideoTrack(fileHandle, timeScale,
                                  MP4_INVALID_DURATION, [(MP42VideoTrack*)track width], [(MP42VideoTrack*)track height]);

            [[track trackImporterHelper] setActiveTrack:track];
        }

        // AAC audio track
        else if ([track isMemberOfClass:[MP42AudioTrack class]] && [track.format isEqualToString:@"AAC"]) {
            dstTrackId = MP4AddAudioTrack(fileHandle,
                                          timeScale,
                                          1024, MP4_MPEG4_AUDIO_TYPE);

            if (!track.needConversion && [magicCookie length]) {
                MP4SetTrackESConfiguration(fileHandle, dstTrackId,
                                           [magicCookie bytes],
                                           [magicCookie length]);
            }
            
            [[track trackImporterHelper] setActiveTrack:track];
        }

        // AC-3 audio track
        else if ([track isMemberOfClass:[MP42AudioTrack class]] && [track.format isEqualToString:@"AC-3"]) {
            if ([magicCookie length] < sizeof(uint64_t) * 6)
                continue;

            const uint64_t * ac3Info = (const uint64_t *)[magicCookie bytes];

            dstTrackId = MP4AddAC3AudioTrack(fileHandle,
                                             timeScale,
                                             ac3Info[0],
                                             ac3Info[1],
                                             ac3Info[2],
                                             ac3Info[3],
                                             ac3Info[4],
                                             ac3Info[5]);

            [[track trackImporterHelper] setActiveTrack:track];
        }

        // ALAC audio track
        else if ([track isMemberOfClass:[MP42AudioTrack class]] && [track.format isEqualToString:@"ALAC"]) {
            dstTrackId = MP4AddALACAudioTrack(fileHandle,
                                          timeScale);
            if ([magicCookie length])
                MP4SetTrackBytesProperty(fileHandle, dstTrackId, "mdia.minf.stbl.stsd.alac.alac.AppleLosslessMagicCookie", [magicCookie bytes], [magicCookie length]);

            [[track trackImporterHelper] setActiveTrack:track];
        }

        // DTS audio track
        else if ([track isMemberOfClass:[MP42AudioTrack class]] && [track.format isEqualToString:@"DTS"]) {
            dstTrackId = MP4AddAudioTrack(fileHandle,
                                          timeScale,
                                          512, 0xA9);

            MP4SetTrackIntegerProperty(fileHandle, dstTrackId, "mdia.minf.stbl.stsd.*.channels", [(MP42AudioTrack*)track channels]);
            [[track trackImporterHelper] setActiveTrack:track];
        }

        // 3GPP text track
        else if ([track isMemberOfClass:[MP42SubtitleTrack class]] && [track.format isEqualToString:@"3GPP Text"]) {
            NSSize subSize = NSMakeSize(0, 0);
            NSSize videoSize = NSMakeSize(0, 0);

            NSInteger vPlacement = [(MP42SubtitleTrack*)track verticalPlacement];

            for (id track in workingTracks)
                if ([track isMemberOfClass:[MP42VideoTrack class]]) {
                    videoSize.width  = [track trackWidth];
                    videoSize.height = [track trackHeight];
                    break;
                }

            if (!videoSize.width) {
                MP4TrackId videoTrack = findFirstVideoTrack(fileHandle);
                if (videoTrack) {
                    videoSize.width = getFixedVideoWidth(fileHandle, videoTrack);
                    videoSize.height = MP4GetTrackVideoHeight(fileHandle, videoTrack);
                }
                else {
                    videoSize.width = 640;
                    videoSize.height = 480;
                }
            }
            if (!vPlacement) {
                if ([(MP42SubtitleTrack*)track trackHeight])
                    subSize.height = [(MP42SubtitleTrack*)track trackHeight];
                else
                    subSize.height = 0.15 * videoSize.height;
            }
            else
                subSize.height = videoSize.height;

            const uint8_t textColor[4] = { 255,255,255,255 };
            dstTrackId = MP4AddSubtitleTrack(fileHandle, timeScale, videoSize.width, subSize.height);

            MP4SetTrackDurationPerChunk(fileHandle, dstTrackId, timeScale / 8);
            MP4SetTrackIntegerProperty(fileHandle, dstTrackId, "tkhd.alternate_group", 2);
            MP4SetTrackIntegerProperty(fileHandle, dstTrackId, "tkhd.layer", -1);

            int32_t displayFlags = 0;
            if (vPlacement)
                displayFlags = 0x20000000;
            if ([(MP42SubtitleTrack*)track someSamplesAreForced])
                displayFlags += 0x40000000;
            else if ([(MP42SubtitleTrack*)track allSamplesAreForced])
                displayFlags += 0xC0000000;

            MP4SetTrackIntegerProperty(fileHandle, dstTrackId, "mdia.minf.stbl.stsd.tx3g.displayFlags", displayFlags);

            MP4SetTrackIntegerProperty(fileHandle, dstTrackId, "mdia.minf.stbl.stsd.tx3g.horizontalJustification", 1);
            MP4SetTrackIntegerProperty(fileHandle, dstTrackId, "mdia.minf.stbl.stsd.tx3g.verticalJustification", -1);

            MP4SetTrackIntegerProperty(fileHandle, dstTrackId, "mdia.minf.stbl.stsd.tx3g.bgColorRed", 0);
            MP4SetTrackIntegerProperty(fileHandle, dstTrackId, "mdia.minf.stbl.stsd.tx3g.bgColorGreen", 0);
            MP4SetTrackIntegerProperty(fileHandle, dstTrackId, "mdia.minf.stbl.stsd.tx3g.bgColorBlue", 0);
            MP4SetTrackIntegerProperty(fileHandle, dstTrackId, "mdia.minf.stbl.stsd.tx3g.bgColorAlpha", 0);

            MP4SetTrackIntegerProperty(fileHandle, dstTrackId, "mdia.minf.stbl.stsd.tx3g.defTextBoxBottom", subSize.height);
            MP4SetTrackIntegerProperty(fileHandle, dstTrackId, "mdia.minf.stbl.stsd.tx3g.defTextBoxRight", videoSize.width);

            MP4SetTrackIntegerProperty(fileHandle, dstTrackId, "mdia.minf.stbl.stsd.tx3g.fontSize", videoSize.height * 0.05);

            MP4SetTrackIntegerProperty(fileHandle, dstTrackId, "mdia.minf.stbl.stsd.tx3g.fontColorRed", textColor[0]);
            MP4SetTrackIntegerProperty(fileHandle, dstTrackId, "mdia.minf.stbl.stsd.tx3g.fontColorGreen", textColor[1]);
            MP4SetTrackIntegerProperty(fileHandle, dstTrackId, "mdia.minf.stbl.stsd.tx3g.fontColorBlue", textColor[2]);
            MP4SetTrackIntegerProperty(fileHandle, dstTrackId, "mdia.minf.stbl.stsd.tx3g.fontColorAlpha", textColor[3]);

            /* translate the track */
            if (!vPlacement) {
                uint8_t* val;
                uint8_t nval[36];
                uint32_t *ptr32 = (uint32_t*) nval;
                uint32_t size;

                MP4GetTrackBytesProperty(fileHandle, dstTrackId, "tkhd.matrix", &val, &size);
                memcpy(nval, val, size);
                ptr32[7] = CFSwapInt32HostToBig( (videoSize.height * 0.85) * 0x10000);

                MP4SetTrackBytesProperty(fileHandle, dstTrackId, "tkhd.matrix", nval, size);
                free(val);
            }

            [[track trackImporterHelper] setActiveTrack:track];
        }
        // VobSub bitmap track
        else if ([track isMemberOfClass:[MP42SubtitleTrack class]] && [track.format isEqualToString:@"VobSub"]) {
            if ([magicCookie length] < sizeof(uint32_t) * 16)
                continue;

            dstTrackId = MP4AddSubpicTrack(fileHandle, timeScale, 640, 480);

            uint32_t *subPalette = (uint32_t*) [magicCookie bytes];
            int ii;
            for ( ii = 0; ii < 16; ii++ )
                subPalette[ii] = rgb2yuv(subPalette[ii]);

            uint8_t palette[16][4];
            for ( ii = 0; ii < 16; ii++ ) {
                palette[ii][0] = 0;
                palette[ii][1] = (subPalette[ii] >> 16) & 0xff;
                palette[ii][2] = (subPalette[ii] >> 8) & 0xff;
                palette[ii][3] = (subPalette[ii]) & 0xff;
            }
            MP4SetTrackESConfiguration( fileHandle, dstTrackId,
                                             (uint8_t*)palette, 16 * 4 );

            [[track trackImporterHelper] setActiveTrack:track];
        }

        // Closed Caption text track
        else if ([track isMemberOfClass:[MP42ClosedCaptionTrack class]]) {
            NSSize videoSize = [[track trackImporterHelper] sizeForTrack:track];

            for (id track in workingTracks)
                if ([track isMemberOfClass:[MP42VideoTrack class]]) {
                    videoSize.width  = [track trackWidth];
                    videoSize.height = [track trackHeight];
                    break;
                }

            if (!videoSize.width) {
                MP4TrackId videoTrack = findFirstVideoTrack(fileHandle);
                if (videoTrack) {
                    videoSize.width = getFixedVideoWidth(fileHandle, videoTrack);
                    videoSize.height = MP4GetTrackVideoHeight(fileHandle, videoTrack);
                }
                else {
                    videoSize.width = 640;
                    videoSize.height = 480;
                }
            }

            dstTrackId = MP4AddCCTrack(fileHandle, timeScale, videoSize.width, videoSize.height);

            [[track trackImporterHelper] setActiveTrack:track];
        }
        else {
            continue;
        }

        MP4SetTrackDurationPerChunk(fileHandle, dstTrackId, timeScale / 8);
        track.Id = dstTrackId;

        if (track.trackConverterHelper)
            [track.trackConverterHelper setOutputTrack:track.Id];
    }

    return noErr;
}

- (void)start:(MP4FileHandle)fileHandle
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSMutableArray * trackImportersArray = [[NSMutableArray alloc] init];

    for (MP42Track * track in workingTracks) {
        if (![trackImportersArray containsObject:[track trackImporterHelper]]) {
            [trackImportersArray addObject:[track trackImporterHelper]];
        }
    }

    CGFloat status = 0;
    NSUInteger currentNumber = 0;
    NSInteger tracksImportersCount = [trackImportersArray count];

    if (!tracksImportersCount) {
        [trackImportersArray release];
        return;
    }

    for (id importerHelper in trackImportersArray) {
        MP42SampleBuffer * sampleBuffer;

        while ((sampleBuffer = [importerHelper copyNextSample]) != nil && !isCancelled) {
            // The sample need additional conversion
            if (sampleBuffer->sampleSourceTrack) {
                MP42SampleBuffer *convertedSample;
                id converter = sampleBuffer->sampleSourceTrack.trackConverterHelper;
                [converter addSample:sampleBuffer];
                while (![converter needMoreSample]) {
                    convertedSample = [converter copyEncodedSample];
                    if (convertedSample != nil) {
                        MP4WriteSample(fileHandle, convertedSample->sampleTrackId,
                                       convertedSample->sampleData, convertedSample->sampleSize,
                                       convertedSample->sampleDuration, convertedSample->sampleOffset,
                                       convertedSample->sampleIsSync);
                        [convertedSample release];
                    }
                    else if (![converter encoderDone]) {
                        usleep(50);
                    }
                    else
                        break;

                }
                [sampleBuffer release];
            }

            // Write the sample directly to the file
            else {
                if (!MP4WriteSample(fileHandle, sampleBuffer->sampleTrackId,
                               sampleBuffer->sampleData, sampleBuffer->sampleSize,
                               sampleBuffer->sampleDuration, sampleBuffer->sampleOffset,
                               sampleBuffer->sampleIsSync))
                    isCancelled = YES;
                else
                    [sampleBuffer release];
            }

            if (currentNumber == 150) {
                status = [importerHelper progress] / tracksImportersCount;

                if ([delegate respondsToSelector:@selector(progressStatus:)]) 
                    [delegate progressStatus:status];
                currentNumber = 0;
            }
            else {
                currentNumber++;
            }
        }
        if (isCancelled)
            [sampleBuffer release];
    }

    for (id importerHelper in trackImportersArray) {
        if (isCancelled)
            [importerHelper cancel];
        else
            [importerHelper cleanUp:fileHandle];
    }

    // Write the last samples from the encoder
    for (MP42Track * track in workingTracks) {
        if(track.trackConverterHelper && track.needConversion) {
            id converter = track.trackConverterHelper;
            [converter setDone:YES];
            MP42SampleBuffer *convertedSample;
            while (![converter encoderDone]) {
                if ((convertedSample = [converter copyEncodedSample]) != nil) {
                    MP4WriteSample(fileHandle, convertedSample->sampleTrackId,
                                   convertedSample->sampleData, convertedSample->sampleSize,
                                   convertedSample->sampleDuration, convertedSample->sampleOffset,
                                   convertedSample->sampleIsSync);
                    [convertedSample release];
                }
                else {
                    usleep(50);
                }

            }
            if ([track isMemberOfClass:[MP42AudioTrack class]]) {
                NSData *magicCookie = [track.trackConverterHelper magicCookie];
                MP4SetTrackESConfiguration(fileHandle, track.Id,
                                           [magicCookie bytes],
                                           [magicCookie length]);
            }
        }
    }

    [trackImportersArray release];
    [pool release];
}

- (void)cancel
{
    isCancelled = YES;
}

- (void) dealloc
{
    [workingTracks release], workingTracks = nil;
    [super dealloc];
}

@end
