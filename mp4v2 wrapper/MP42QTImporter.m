//
//  MP42MkvFileImporter.m
//  Subler
//
//  Created by Damiano Galassi on 31/01/10.
//  Copyright 2010 Damiano Galassi All rights reserved.
//

#if !__LP64__
#import "MP42QTImporter.h"
#import "MP42File.h"
#import <AudioToolbox/AudioToolbox.h>
#import <QuickTime/QuickTime.h>
#import "SBLanguages.h"
#import "QTKitDecrap.h"
#include "avcodec.h"

@interface MP42QTImporter(Private)
    -(void) movieLoaded;
    -(NSString*)formatForTrack: (QTTrack *)track;
    -(NSString*)langForTrack: (QTTrack *)track;
@end

@interface MovTrackHelper : NSObject {
@public
    MP4SampleId     currentSampleId;
    uint64_t        totalSampleNumber;
    int64_t         minDisplayOffset;
    MP4Timestamp    currentTime;
}
@end

@implementation MovTrackHelper

@end

@implementation MP42QTImporter

- (id)initWithDelegate:(id)del andFile:(NSURL *)URL error:(NSError **)outError
{
    if ((self = [super init])) {
        delegate = del;
        fileURL = [URL retain];

		NSDictionary * dict = [NSDictionary dictionaryWithObjectsAndKeys:
							   fileURL, QTMovieURLAttribute,
							   [NSNumber numberWithBool:NO], @"QTMovieOpenAsyncRequiredAttribute",
							   [NSNumber numberWithBool:NO], @"QTMovieOpenAsyncOKAttribute",
							   nil];

        if (dispatch_get_current_queue() != dispatch_get_main_queue()) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                sourceFile = [[QTMovie alloc] initWithAttributes:dict
                                                           error:outError];
            });
        }
        else
            sourceFile = [[QTMovie alloc] initWithAttributes:dict
                                                       error:outError];

		if (sourceFile)
			[self movieLoaded];
		else {
            [self release];

			return nil;
        }
    }

    return self;
}

-(void) movieLoaded
{
    for (QTTrack *track in [sourceFile tracks])
        if ([[track attributeForKey:QTTrackIsChapterTrackAttribute] boolValue])
            chapterTrackId = [[track attributeForKey:QTTrackIDAttribute] integerValue];

    tracksArray = [[NSMutableArray alloc] init];

    if (NSClassFromString(@"QTMetadataItem")) //QTMetadataItem is only 10.7+
        [self convertMetadata];

    for (QTTrack *track in [sourceFile tracks]) {
        NSString* mediaType = [track attributeForKey:QTTrackMediaTypeAttribute];
        MP42Track *newTrack = nil;

        Track qtcTrack = [track quickTimeTrack];
        Media media = GetTrackMedia(qtcTrack);

        // Video
        if ([mediaType isEqualToString:QTMediaTypeVideo]) {
            if ([[self formatForTrack:track] isEqualToString:@"Text"]) {
                newTrack = [[MP42SubtitleTrack alloc] init];
                [(MP42SubtitleTrack*)newTrack setTrackWidth:80];
            }
            else {
                newTrack = [[MP42VideoTrack alloc] init];

                NSSize dimension = [track apertureModeDimensionsForMode:QTMovieApertureModeClean];
                [(MP42VideoTrack*)newTrack setTrackWidth: dimension.width];
                [(MP42VideoTrack*)newTrack setTrackHeight: dimension.height];

                long count;
                // Get the sample description
                SampleDescriptionHandle desc = (SampleDescriptionHandle) NewHandle(0);
                GetMediaSampleDescription(media, 1, desc);
                ImageDescriptionHandle imgDesc = (ImageDescriptionHandle) desc;

				// Get dimensions of track media and define video dimensions accordingly.
				[(MP42VideoTrack*)newTrack setWidth: (**imgDesc).width];
				[(MP42VideoTrack*)newTrack setHeight: (**imgDesc).height];

                // Read pixel aspect ratio
                CountImageDescriptionExtensionType(imgDesc, kPixelAspectRatioImageDescriptionExtension, &count);
                if (count > 0) {
                    Handle pasp = NewHandle(0);
                    GetImageDescriptionExtension(imgDesc, &pasp, kPixelAspectRatioImageDescriptionExtension, 1);
                    [(MP42VideoTrack*)newTrack setHSpacing:CFSwapInt32BigToHost(((PixelAspectRatioImageDescriptionExtension*)(*pasp))->hSpacing)];
                    [(MP42VideoTrack*)newTrack setVSpacing: CFSwapInt32BigToHost(((PixelAspectRatioImageDescriptionExtension*)(*pasp))->vSpacing)];
                    DisposeHandle(pasp);
                }
				// Hack to setup PASP if none exists
				else if (dimension.width != (**imgDesc).width) { 
					AVRational dar, invPixelSize, sar;
					dar			   = (AVRational){dimension.width, dimension.height};
					invPixelSize   = (AVRational){(**imgDesc).width, (**imgDesc).height};
					sar = av_mul_q(dar, invPixelSize);

					av_reduce(&sar.num, &sar.den, sar.num, sar.den, fixed1);

					[(MP42VideoTrack*)newTrack setHSpacing:sar.num];
					[(MP42VideoTrack*)newTrack setVSpacing:sar.den];
				}
            }
        }

        // Audio
        else if ([mediaType isEqualToString:QTMediaTypeSound]) {
            newTrack = [[MP42AudioTrack alloc] init];

			OSStatus err = noErr;

			// Get the sample description
			SampleDescriptionHandle desc = (SampleDescriptionHandle) NewHandle(0);
			GetMediaSampleDescription(media, 1, desc);			

			ByteCount           channelLayoutSize;
            AudioChannelLayout *channelLayout = NULL;

			SoundDescriptionHandle sndDesc = (SoundDescriptionHandle) desc;

            err = QTSoundDescriptionGetPropertyInfo(sndDesc, kQTPropertyClass_SoundDescription,
                                                    kQTSoundDescriptionPropertyID_AudioChannelLayout,
                                                    NULL, &channelLayoutSize, NULL);
            require_noerr(err, bail);

            channelLayout = (AudioChannelLayout*)malloc(channelLayoutSize);

            err = QTSoundDescriptionGetProperty(sndDesc, kQTPropertyClass_SoundDescription,
                                                kQTSoundDescriptionPropertyID_AudioChannelLayout,
                                                channelLayoutSize, channelLayout, NULL);
            require_noerr(err, bail);

            UInt32 channelNumber = AudioChannelLayoutTag_GetNumberOfChannels(channelLayout->mChannelLayoutTag);
            if (!channelNumber)
                channelNumber = channelLayout->mNumberChannelDescriptions;

            [(MP42AudioTrack*)newTrack setChannelLayoutTag: channelLayout->mChannelLayoutTag];

			bail:
			if (err) {
				NSLog(@"Error: unable to read the sound description, guessing 1 channel");
                channelNumber = 1;
            }

            [(MP42AudioTrack*)newTrack setChannels: channelNumber];

			if (channelLayout)
				free(channelLayout);
		}

        // Text
        else if ([mediaType isEqualToString:QTMediaTypeText]) {
            if ([[track attributeForKey:QTTrackIDAttribute] integerValue] == chapterTrackId) {
                newTrack = [[MP42ChapterTrack alloc] init];
                NSArray *chapters = [sourceFile chapters];

                for (NSDictionary *dic in chapters) {
                    QTTimeRange time = [[dic valueForKey:QTMovieChapterStartTime] QTTimeRangeValue];
                    [(MP42ChapterTrack*)newTrack addChapter:[dic valueForKey:QTMovieChapterName]
                                                    duration:((float)time.time.timeValue / time.time.timeScale)*1000];
                }
            }
        }

        // Subtitle
        else if([mediaType isEqualToString:@"sbtl"]) {
            newTrack = [[MP42SubtitleTrack alloc] init];
            NSSize dimension = [track apertureModeDimensionsForMode:QTMovieApertureModeClean];
            [(MP42SubtitleTrack*)newTrack setTrackWidth: dimension.width];
            [(MP42SubtitleTrack*)newTrack setTrackHeight: dimension.height];
            [(MP42SubtitleTrack*)newTrack setWidth: dimension.width];
            [(MP42SubtitleTrack*)newTrack setHeight: dimension.height];
        }

        // Closed Caption
        else if([mediaType isEqualToString:@"clcp"])
            newTrack = [[MP42ClosedCaptionTrack alloc] init];

        else
            newTrack = [[MP42Track alloc] init];

        if (newTrack) {
            newTrack.format = [self formatForTrack:track];
            newTrack.sourceFormat = newTrack.format;
            newTrack.Id = [[track attributeForKey:QTTrackIDAttribute] integerValue];
            newTrack.sourceURL = fileURL;
            newTrack.sourceFileHandle = sourceFile;
            newTrack.name = [track attributeForKey:QTTrackDisplayNameAttribute];
            newTrack.language = [self langForTrack:track];

            TimeValue64 duration = GetMediaDisplayDuration(media) / GetMediaTimeScale(media) * 1000;
            newTrack.duration = duration;

            [tracksArray addObject:newTrack];
            [newTrack release];
        }
    }
}

- (NSString*)formatForTrack: (QTTrack *)track;
{
    NSString* result = @"";

    ImageDescriptionHandle idh = (ImageDescriptionHandle) NewHandleClear(sizeof(ImageDescription));
    GetMediaSampleDescription([[track media] quickTimeMedia], 1,
                              (SampleDescriptionHandle)idh);
    
    switch ((*idh)->cType) {
        case kH264CodecType:
            result = @"H.264";
            break;
        case kMPEG4VisualCodecType:
            result = @"MPEG-4 Visual";
            break;
        case kSorensonCodecType:
            result = @"Sorenson Video";
            break;
        case kSorenson3CodecType:
            result = @"Sorenson Video 3";
            break;
        case 'ap4h':
        case 'apch':
        case 'apcn':
        case 'apcs':
        case 'apco':
            result = @"ProRes";
            break;
        case 'png ':
            result = @"PNG";
            break;
        case kAnimationCodecType:
            result = @"Animation";
            break;
        case kAudioFormatMPEG4AAC:
        case 'mp4a':
            result = @"AAC";
            break;
        case kAudioFormatMPEG4AAC_HE:
        case kAudioFormatMPEG4AAC_HE_V2:
            result = @"HE-AAC";
            break;
        case kAudioFormatLinearPCM:
        case kRawCodecType:
        case 'twos':
        case 'sowt':
            result = @"PCM";
            break;
        case kAudioFormatAppleLossless:
            result = @"ALAC";
            break;
        case kAudioFormatAC3:
        case 'ms \0':
            result = @"AC-3";
            break;
        case kAudioFormatMPEGLayer1:
        case kAudioFormatMPEGLayer2:
        case kAudioFormatMPEGLayer3:
        case 'ms\0U':
            result = @"MP3";
            break;
        case kAudioFormatAMR:
            result = @"AMR Narrow Band";
            break;
        case TextMediaType:
            result = @"Text";
            break;
        case kTx3gSampleType:
            result = @"3GPP Text";
            break;
        case 'SRT ':
            result = @"Text";
            break;
        case 'SSA ':
            result = @"SSA";
            break;
        case 'c608':
            result = @"CEA-608";
            break;
        case kDVCNTSCCodecType:
        case kDVCPALCodecType:
            result = @"DV";
            break;
        case 'm2v1':
            result = @"MPEG-2";
            break;
        case kMotionJPEGACodecType:
        case kMotionJPEGBCodecType:
            result = @"Motion JPEG";
            break;
        case TimeCodeMediaType:
            result = @"Timecode";
            break;
        case kJPEGCodecType:
            result = @"Photo - JPEG";
            break;
        default:
            result = @"Unknown";
            break;
    }
    DisposeHandle((Handle)idh);

    return result;
}

- (NSString*)langForTrack: (QTTrack *)track
{
    long data = [[track attributeForKey:QTTrackLanguageAttribute] longValue];
    char code[4];
    NSString *language;

    language = [NSString stringWithUTF8String:lang_for_qtcode(data)->eng_name];

    if ([language isEqualToString:@"Unknown"])
    {
        code[0] = ((data & 0x7c00) >> 10) + 0x60;
        code[1] = ((data & 0x03e0) >>  5) + 0x60;
        code[2] = ((data & 0x001f)      ) + 0x60;
        code[3] = '\0';

        language = [NSString stringWithFormat:@"%s", lang_for_code2(code)->eng_name];
    }

    return language;
}

-(void)convertMetadata
{
    NSArray *items = nil;
    NSDictionary *commonItemsDict = [NSDictionary dictionaryWithObjectsAndKeys:@"Name", QTMetadataCommonKeyTitle,
                                     //nil, QTMetadataCommonKeyCreator,
                                     //nil, QTMetadataCommonKeySubject,
                                     @"Description", QTMetadataCommonKeyDescription,
                                     @"Publisher", QTMetadataCommonKeyPublisher,
                                     //nil, QTMetadataCommonKeyContributor,
                                     @"Release Date", QTMetadataCommonKeyCreationDate,
                                     //nil, QTMetadataCommonKeyLastModifiedDate,
                                     @"Genre", QTMetadataCommonKeyType,
                                     //nil, QTMetadataCommonKeyFormat,
                                     //nil, QTMetadataCommonKeyIdentifier,
                                     //nil, QTMetadataCommonKeySource,
                                     //nil, QTMetadataCommonKeyLanguage,
                                     //nil, QTMetadataCommonKeyRelation,
                                     //nil, QTMetadataCommonKeyLocation,
                                     @"Copyright", QTMetadataCommonKeyCopyrights,
                                     @"Album", QTMetadataCommonKeyAlbumName,
                                     //nil, QTMetadataCommonKeyAuthor,
                                     //nil, QTMetadataCommonKeyArtwork
                                     @"Artist", QTMetadataCommonKeyArtist,
                                     //nil, QTMetadataCommonKeyMake,
                                     //nil, QTMetadataCommonKeyModel,
                                     @"Encoding Tool", QTMetadataCommonKeySoftware,
                                     nil];

    metadata = [[MP42Metadata alloc] init];
    for (NSString *commonKey in [commonItemsDict allKeys]) {
        items = [QTMetadataItem metadataItemsFromArray:[sourceFile commonMetadata] withKey:[commonKey stringByReplacingOccurrencesOfString:@"@" withString:@"©"] keySpace:nil];
        if ([items count])
            [metadata setTag:[[items lastObject] value] forKey:[commonItemsDict objectForKey:commonKey]];
    }

    items = [QTMetadataItem metadataItemsFromArray:[sourceFile commonMetadata] withKey:[QTMetadataCommonKeyArtwork stringByReplacingOccurrencesOfString:@"@" withString:@"©"] keySpace:nil];
    if ([items count]) {
        id artworkData = [[items lastObject] value];
        if ([artworkData isKindOfClass:[NSData class]]) {
            NSImage *image = [[NSImage alloc] initWithData:artworkData];
            [metadata setArtwork:image];
            [image release];
        }
    }

    NSArray* availableMetadataFormats = [sourceFile availableMetadataFormats];

    if ([availableMetadataFormats containsObject:QTMetadataFormatiTunesMetadata]) {
        NSArray* itunesMetadata = [sourceFile metadataForFormat:QTMetadataFormatiTunesMetadata];

        NSDictionary *itunesMetadataDict = [NSDictionary dictionaryWithObjectsAndKeys:
                                            @"Album",               QTMetadataiTunesMetadataKeyAlbum,
                                            @"Artist",              QTMetadataiTunesMetadataKeyArtist,
                                            @"Comments",            QTMetadataiTunesMetadataKeyUserComment,
                                            //QTMetadataiTunesMetadataKeyCoverArt,
                                            @"Copyright",           QTMetadataiTunesMetadataKeyCopyright,
                                            @"Release Date",        QTMetadataiTunesMetadataKeyReleaseDate,
                                            @"Encoded By",          QTMetadataiTunesMetadataKeyEncodedBy,
                                            //@"Genre",             QTMetadataiTunesMetadataKeyPredefinedGenre,
                                            @"Genre",               QTMetadataiTunesMetadataKeyUserGenre,
                                            @"Name",                QTMetadataiTunesMetadataKeySongName,
                                            @"Track Sub-Title",     QTMetadataiTunesMetadataKeyTrackSubTitle,
                                            @"Encoding Tool",       QTMetadataiTunesMetadataKeyEncodingTool,
                                            @"Composer",            QTMetadataiTunesMetadataKeyComposer,
                                            @"Album Artist",        QTMetadataiTunesMetadataKeyAlbumArtist,
                                            @"iTunes Account Type", QTMetadataiTunesMetadataKeyAccountKind,
                                            @"iTunes Account",      QTMetadataiTunesMetadataKeyAppleID,
                                            @"artistID",            QTMetadataiTunesMetadataKeyArtistID,
                                            @"content ID",          QTMetadataiTunesMetadataKeySongID,
                                            @"Compilation",         QTMetadataiTunesMetadataKeyDiscCompilation,
                                            @"Disk #",              QTMetadataiTunesMetadataKeyDiscNumber,
                                            @"genreID",             QTMetadataiTunesMetadataKeyGenreID,
                                            @"Grouping",            QTMetadataiTunesMetadataKeyGrouping,
                                            @"playlistID",          QTMetadataiTunesMetadataKeyPlaylistID,
                                            @"Content Rating",      QTMetadataiTunesMetadataKeyContentRating,
                                            @"Rating",              @"com.apple.iTunes.iTunEXTC",
                                            @"Tempo",               QTMetadataiTunesMetadataKeyBeatsPerMin,
                                            @"Track #",             QTMetadataiTunesMetadataKeyTrackNumber,
                                            @"Art Director",        QTMetadataiTunesMetadataKeyArtDirector,
                                            @"Arranger",            QTMetadataiTunesMetadataKeyArranger,
                                            @"Lyricist",            QTMetadataiTunesMetadataKeyAuthor,
                                            @"Lyrics",              QTMetadataiTunesMetadataKeyLyrics,
                                            @"Acknowledgement",     QTMetadataiTunesMetadataKeyAcknowledgement,
                                            @"Conductor",           QTMetadataiTunesMetadataKeyConductor,
                                            @"Song Description",    QTMetadataiTunesMetadataKeyDescription,
                                            @"Description",         @"desc",
                                            @"Long Description",    @"ldes",
                                            @"Media Kind",          @"stik",
                                            @"TV Show",             @"tvsh",
                                            @"TV Episode #",        @"tves",
                                            @"TV Network",          @"tvnn",
                                            @"TV Episode ID",       @"tven",
                                            @"TV Season",           @"tvsn",
                                            @"HD Video",            @"hdvd",
                                            @"Gapless",             @"pgap",
                                            @"Sort Name",           @"sonm",
                                            @"Sort Artist",         @"soar",
                                            @"Sort Album Artist",   @"soaa",
                                            @"Sort Album",          @"soal",
                                            @"Sort Composer",       @"soco",
                                            @"Sort TV Show",        @"sosn",
                                            @"Category",            @"catg",
                                            @"iTunes U",            @"itnu",
                                            @"Purchase Date",       @"purd",
                                            @"Director",            QTMetadataiTunesMetadataKeyDirector,
                                            //QTMetadataiTunesMetadataKeyEQ,
                                            @"Linear Notes",        QTMetadataiTunesMetadataKeyLinerNotes,
                                            @"Record Company",      QTMetadataiTunesMetadataKeyRecordCompany,
                                            @"Original Artist",     QTMetadataiTunesMetadataKeyOriginalArtist,
                                            @"Phonogram Rights",    QTMetadataiTunesMetadataKeyPhonogramRights,
                                            @"Producer",            QTMetadataiTunesMetadataKeyProducer,
                                            @"Performer",           QTMetadataiTunesMetadataKeyPerformer,
                                            @"Publisher",           QTMetadataiTunesMetadataKeyPublisher,
                                            @"Sound Engineer",      QTMetadataiTunesMetadataKeySoundEngineer,
                                            @"Soloist",             QTMetadataiTunesMetadataKeySoloist,
                                            @"Credits",             QTMetadataiTunesMetadataKeyCredits,
                                            @"Thanks",              QTMetadataiTunesMetadataKeyThanks,
                                            @"Online Extras",       QTMetadataiTunesMetadataKeyOnlineExtras,
                                            @"Executive Producer",  QTMetadataiTunesMetadataKeyExecProducer,
                                            nil];

        for (NSString *itunesKey in [itunesMetadataDict allKeys]) {
            items = [QTMetadataItem metadataItemsFromArray:itunesMetadata withKey:[itunesKey stringByReplacingOccurrencesOfString:@"@" withString:@"©"] keySpace:nil];
            if ([items count]) {
                [metadata setTag:[[items lastObject] value] forKey:[itunesMetadataDict objectForKey:itunesKey]];
            }
        }

        items = [QTMetadataItem metadataItemsFromArray:itunesMetadata withKey:[QTMetadataiTunesMetadataKeyCoverArt stringByReplacingOccurrencesOfString:@"@" withString:@"©"] keySpace:nil];
        if ([items count]) {
            id artworkData = [[items lastObject] value];
            if ([artworkData isKindOfClass:[NSData class]]) {
                NSImage *image = [[NSImage alloc] initWithData:artworkData];
                [metadata setArtwork:image];
                [image release];
            }
        }
    }
    if ([availableMetadataFormats containsObject:QTMetadataFormatQuickTimeMetadata]) {
        NSArray* quicktimeMetadata = [sourceFile metadataForFormat:QTMetadataFormatQuickTimeMetadata];

        NSDictionary *quicktimeMetadataDict = [NSDictionary dictionaryWithObjectsAndKeys:
                                               @"Arist",        QTMetadataQuickTimeMetadataKeyAuthor,
                                               @"Comments",     QTMetadataQuickTimeMetadataKeyComment,
                                               @"Copyright",    QTMetadataQuickTimeMetadataKeyCopyright,
                                               @"Release Date", QTMetadataQuickTimeMetadataKeyCreationDate,
                                               @"Director",     QTMetadataQuickTimeMetadataKeyDirector,
                                               @"Name",         QTMetadataQuickTimeMetadataKeyDisplayName,
                                               @"Description",  QTMetadataQuickTimeMetadataKeyInformation,
                                               @"Keyworkds",    QTMetadataQuickTimeMetadataKeyKeywords,
                                               @"Producer",     QTMetadataQuickTimeMetadataKeyProducer,
                                               @"Publisher",    QTMetadataQuickTimeMetadataKeyPublisher,
                                               @"Album",        QTMetadataQuickTimeMetadataKeyAlbum,
                                               @"Artist",       QTMetadataQuickTimeMetadataKeyArtist,
                                               @"Description",  QTMetadataQuickTimeMetadataKeyDescription,
                                               @"Encoding Tool",QTMetadataQuickTimeMetadataKeySoftware,
                                               @"Genre",        QTMetadataQuickTimeMetadataKeyGenre,
                                               //QTMetadataQuickTimeMetadataKeyiXML,
                                               @"Arranger",     QTMetadataQuickTimeMetadataKeyArranger,
                                               @"Encoded By",   QTMetadataQuickTimeMetadataKeyEncodedBy,
                                               @"Original Artist",  QTMetadataQuickTimeMetadataKeyOriginalArtist,
                                               @"Performer",    QTMetadataQuickTimeMetadataKeyPerformer,
                                               @"Composer",     QTMetadataQuickTimeMetadataKeyComposer,
                                               @"Credits",      QTMetadataQuickTimeMetadataKeyCredits,
                                               @"Phonogram Rights", QTMetadataQuickTimeMetadataKeyPhonogramRights, nil];
        
        for (NSString *qtKey in [quicktimeMetadataDict allKeys]) {
            items = [QTMetadataItem metadataItemsFromArray:quicktimeMetadata withKey:[qtKey stringByReplacingOccurrencesOfString:@"@" withString:@"©"] keySpace:nil];
            if ([items count]) {
                [metadata setTag:[[items lastObject] value] forKey:[quicktimeMetadataDict objectForKey:qtKey]];
            }
        }
    }
    if ([availableMetadataFormats containsObject:QTMetadataFormatQuickTimeUserData]) {
        NSArray* quicktimeUserDataMetadata = [sourceFile metadataForFormat:QTMetadataFormatQuickTimeUserData];
        
        NSDictionary *quicktimeUserDataMetadataDict = [NSDictionary dictionaryWithObjectsAndKeys:
                                                       @"Album",                QTMetadataQuickTimeUserDataKeyAlbum,
                                                       @"Arranger",             QTMetadataQuickTimeUserDataKeyArranger,
                                                       @"Artist",               QTMetadataQuickTimeUserDataKeyArtist,
                                                       @"Lyricist",             QTMetadataQuickTimeUserDataKeyAuthor,
                                                       @"Comments",             QTMetadataQuickTimeUserDataKeyComment,
                                                       @"Composer",             QTMetadataQuickTimeUserDataKeyComposer,
                                                       @"Copyright",            QTMetadataQuickTimeUserDataKeyCopyright,
                                                       @"Release Date",         QTMetadataQuickTimeUserDataKeyCreationDate,
                                                       @"Description",          QTMetadataQuickTimeUserDataKeyDescription,
                                                       @"Director",             QTMetadataQuickTimeUserDataKeyDirector,
                                                       @"Encoded By",           QTMetadataQuickTimeUserDataKeyEncodedBy,
                                                       @"Name",                 QTMetadataQuickTimeUserDataKeyFullName,
                                                       @"Genre",                QTMetadataQuickTimeUserDataKeyGenre,
                                                       @"Keywords",             QTMetadataQuickTimeUserDataKeyKeywords,
                                                       @"Original Artist",      QTMetadataQuickTimeUserDataKeyOriginalArtist,
                                                       @"Performer",            QTMetadataQuickTimeUserDataKeyPerformers,
                                                       @"Producer",             QTMetadataQuickTimeUserDataKeyProducer,
                                                       @"Publisher",            QTMetadataQuickTimeUserDataKeyPublisher,
                                                       @"Online Extras",        QTMetadataQuickTimeUserDataKeyURLLink,
                                                       @"Credits",              QTMetadataQuickTimeUserDataKeyCredits,
                                                       @"Phonogram Rights",     QTMetadataQuickTimeUserDataKeyPhonogramRights, nil];
        
        for (NSString *qtUserDataKey in [quicktimeUserDataMetadataDict allKeys]) {
            items = [QTMetadataItem metadataItemsFromArray:quicktimeUserDataMetadata withKey:[qtUserDataKey stringByReplacingOccurrencesOfString:@"@" withString:@"©"] keySpace:nil];
            if ([items count]) {
                [metadata setTag:[[items lastObject] value] forKey:[quicktimeUserDataMetadataDict objectForKey:qtUserDataKey]];
            }
        }
    }
}

- (NSUInteger)timescaleForTrack:(MP42Track *)track
{
    Track qtTrack = [[sourceFile trackWithTrackID:[track sourceId]] quickTimeTrack];
    Media media = GetTrackMedia(qtTrack);

    return GetMediaTimeScale(media);
}

- (NSSize)sizeForTrack:(MP42Track *)track
{
    MP42VideoTrack* currentTrack = (MP42VideoTrack*) track;

    return NSMakeSize([currentTrack width], [currentTrack height]);
}

- (NSData*)magicCookieForTrack:(MP42Track *)track
{      
    OSStatus err = noErr;

    QTTrack * qtTrack = [sourceFile trackWithTrackID:[track sourceId]];;
    NSString* mediaType = [qtTrack attributeForKey:QTTrackMediaTypeAttribute];
    Track qtcTrack = [qtTrack quickTimeTrack];
    Media media = GetTrackMedia(qtcTrack);
    NSMutableData * magicCookie;

    // Get the sample description
    SampleDescriptionHandle desc = (SampleDescriptionHandle) NewHandle(0);
    GetMediaSampleDescription(media, 1, desc);

    if ([mediaType isEqualToString:QTMediaTypeVideo]) {
        ImageDescriptionHandle imgDesc = (ImageDescriptionHandle) desc;

        if ((*imgDesc)->cType == kH264CodecType) {
            // Get avcC atom
            Handle imgDescHandle = NewHandle(0);
            GetImageDescriptionExtension(imgDesc, &imgDescHandle, 'avcC', 1);
            
            magicCookie = [NSData dataWithBytes:*imgDescHandle length:GetHandleSize(imgDescHandle)];

            DisposeHandle(imgDescHandle);

            return magicCookie;
        }
        else if ((*imgDesc)->cType == kMPEG4VisualCodecType) {
            long count;
            // Add ES decoder specific configuration
            CountImageDescriptionExtensionType(imgDesc, 'esds',  &count);
            if (count >= 1) {
                Handle imgDescExt = NewHandle(0);
                UInt8* buffer;
                int size;

                GetImageDescriptionExtension(imgDesc, &imgDescExt, 'esds', 1);

                ReadESDSDescExt(*imgDescExt, &buffer, &size, 1);
                magicCookie = [NSData dataWithBytes:buffer length:size];

                DisposeHandle(imgDescExt);
                
                return magicCookie;
            }
        }
    }
    else if ([mediaType isEqualToString:QTMediaTypeSound]) {
        SoundDescriptionHandle sndDesc = (SoundDescriptionHandle) desc;
        
        AudioStreamBasicDescription asbd = {0};
        err = QTSoundDescriptionGetProperty(sndDesc, kQTPropertyClass_SoundDescription,
                                            kQTSoundDescriptionPropertyID_AudioStreamBasicDescription,
                                            sizeof(asbd), &asbd, NULL);
        if (err)
            return nil;
        
        if (asbd.mFormatID == kAudioFormatMPEG4AAC) {
            // Get the magic cookie
            UInt32 cookieSize;
            void* cookie;
            QTSoundDescriptionGetPropertyInfo(sndDesc,
                                              kQTPropertyClass_SoundDescription,
                                              kQTSoundDescriptionPropertyID_MagicCookie,
                                              NULL, &cookieSize, NULL);
            cookie = malloc(cookieSize);
            QTSoundDescriptionGetProperty(sndDesc,
                                          kQTPropertyClass_SoundDescription,
                                          kQTSoundDescriptionPropertyID_MagicCookie,
                                          cookieSize, cookie, &cookieSize);
            // Extract DecoderSpecific info
            UInt8* buffer;
            int size;
            ReadESDSDescExt(cookie, &buffer, &size, 0);
            magicCookie = [NSData dataWithBytes:buffer length:size];

            free(cookie);
            free(buffer);

            return magicCookie;

        }
        else if(asbd.mFormatID == kAudioFormatAppleLossless) {
            // Get the magic cookie
            UInt32 cookieSize;
            void* cookie;
            QTSoundDescriptionGetPropertyInfo(sndDesc,
                                              kQTPropertyClass_SoundDescription,
                                              kQTSoundDescriptionPropertyID_MagicCookie,
                                              NULL, &cookieSize, NULL);
            cookie = malloc(cookieSize);
            QTSoundDescriptionGetProperty(sndDesc,
                                          kQTPropertyClass_SoundDescription,
                                          kQTSoundDescriptionPropertyID_MagicCookie,
                                          cookieSize, cookie, &cookieSize);
            if (cookieSize > 48)
                // Remove unneeded parts of the cookie, as describred in ALACMagicCookieDescription.txt
                magicCookie = [NSData dataWithBytes:cookie + 24 length:cookieSize - 32];
            else
                magicCookie = [NSData dataWithBytes:cookie length:cookieSize];

            free(cookie);            
            return magicCookie;

        }
        else if (asbd.mFormatID == kAudioFormatAC3 || asbd.mFormatID == 0x6D732000)
        {
            ByteCount           channelLayoutSize;
            AudioChannelLayout* channelLayout = NULL;
            err = QTSoundDescriptionGetPropertyInfo(sndDesc, kQTPropertyClass_SoundDescription,
                                                    kQTSoundDescriptionPropertyID_AudioChannelLayout,
                                                    NULL, &channelLayoutSize, NULL);
            if (err)
                return nil;

            channelLayout = (AudioChannelLayout*)malloc(channelLayoutSize);

            err = QTSoundDescriptionGetProperty(sndDesc, kQTPropertyClass_SoundDescription,
                                                kQTSoundDescriptionPropertyID_AudioChannelLayout,
                                                channelLayoutSize, channelLayout, NULL);
            if (err) {
                free(channelLayout);
                return nil;
            }

            UInt32 bitmapSize = sizeof(AudioChannelLayoutTag);
            UInt32 channelBitmap;
            err = AudioFormatGetProperty(kAudioFormatProperty_BitmapForLayoutTag,
                                   sizeof(AudioChannelLayoutTag), &channelLayout->mChannelLayoutTag,
                                   &bitmapSize, &channelBitmap);

            if (err && AudioChannelLayoutTag_GetNumberOfChannels(channelLayout->mChannelLayoutTag) == 6)
                channelBitmap = 0x3F;

            uint8_t fscod = 0;
            uint8_t bsid = 8;
            uint8_t bsmod = 0;
            uint8_t acmod = 7;
            uint8_t lfeon = (channelBitmap & kAudioChannelBit_LFEScreen) ? 1 : 0;
            uint8_t bit_rate_code = 15;

            switch (AudioChannelLayoutTag_GetNumberOfChannels(channelLayout->mChannelLayoutTag) - lfeon) {
                case 1:
                    acmod = 1;
                    break;
                case 2:
                    acmod = 2;
                    break;
                case 3:
                    if (channelBitmap & kAudioChannelBit_CenterSurround) acmod = 3;
                    else acmod = 4;
                    break;
                case 4:
                    if (channelBitmap & kAudioChannelBit_CenterSurround) acmod = 5;
                    else acmod = 6;
                    break;
                case 5:
                    acmod = 7;
                    break;
                default:
                    break;
            }

            if (asbd.mSampleRate == 48000) fscod = 0;
            else if (asbd.mSampleRate == 44100) fscod = 1;
            else if (asbd.mSampleRate == 32000) fscod = 2;
            else fscod = 3;

            NSMutableData *ac3Info = [[NSMutableData alloc] init];
            [ac3Info appendBytes:&fscod length:sizeof(uint64_t)];
            [ac3Info appendBytes:&bsid length:sizeof(uint64_t)];
            [ac3Info appendBytes:&bsmod length:sizeof(uint64_t)];
            [ac3Info appendBytes:&acmod length:sizeof(uint64_t)];
            [ac3Info appendBytes:&lfeon length:sizeof(uint64_t)];
            [ac3Info appendBytes:&bit_rate_code length:sizeof(uint64_t)];

            free(channelLayout);

            return [ac3Info autorelease];
        }
    }

    return nil;
}

- (AudioStreamBasicDescription)audioDescriptionForTrack:(MP42Track *)track
{
    OSStatus err = noErr;
    NSString* mediaType = [[sourceFile trackWithTrackID:[track sourceId]] attributeForKey:QTTrackMediaTypeAttribute];
    
    Track qtcTrack = [[sourceFile trackWithTrackID:[track sourceId]] quickTimeTrack];
    Media media = GetTrackMedia(qtcTrack);

    // Audio
    if ([mediaType isEqualToString:QTMediaTypeSound]) {
        // Get the sample description
        SampleDescriptionHandle desc = (SampleDescriptionHandle) NewHandle(0);
        GetMediaSampleDescription(media, 1, desc);

        SoundDescriptionHandle sndDesc = (SoundDescriptionHandle) desc;

        ByteCount           formatDescSize;
        AudioStreamBasicDescription formatDesc;

        err = QTSoundDescriptionGetPropertyInfo(sndDesc, kQTPropertyClass_SoundDescription,
                                                kQTSoundDescriptionPropertyID_AudioStreamBasicDescription,
                                                NULL, &formatDescSize, NULL);
        require_noerr(err, bail);

        err = QTSoundDescriptionGetProperty(sndDesc, kQTPropertyClass_SoundDescription,
                                            kQTSoundDescriptionPropertyID_AudioStreamBasicDescription,
                                            formatDescSize, &formatDesc, NULL);
        require_noerr(err, bail);

        bail:
        if (err) {
            NSLog(@"Error: unable to read the audio stream basic description");
        }

        return formatDesc;
    }

    return [super audioDescriptionForTrack:track];
}

- (void) fillMovieSampleBuffer: (id)sender
{
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
    OSStatus err = noErr;

    NSInteger tracksNumber = [activeTracks count];
    NSInteger tracksDone = 0;

    MovTrackHelper * trackHelper=nil; 

    for (MP42Track * track in activeTracks) {
        if (track.trackDemuxerHelper == nil) {
            track.trackDemuxerHelper = [[MovTrackHelper alloc] init];

            Track qtcTrack = [[sourceFile trackWithTrackID:[track sourceId]] quickTimeTrack];
            Media media = GetTrackMedia(qtcTrack);

            trackHelper = track.trackDemuxerHelper;
            trackHelper->totalSampleNumber = GetMediaSampleCount(media);
        }
    }

    for (MP42Track * track in activeTracks) {
        if (isCancelled)
            break;

        Track qtcTrack = [[sourceFile trackWithTrackID:[track sourceId]] quickTimeTrack];
        Media media = GetTrackMedia(qtcTrack);
        trackHelper = track.trackDemuxerHelper;

        // Create a QTSampleTable which contains all the informatio of the track samples.
        TimeValue64 sampleTableStartDecodeTime = 0;
        QTMutableSampleTableRef sampleTable = NULL;
        err = CopyMediaMutableSampleTable(media,
                                          0,
                                          &sampleTableStartDecodeTime,
                                          0,
                                          0,
                                          &sampleTable);
        require_noerr(err, bail);

        TimeValue64 minDisplayOffset = 0;
        err = QTSampleTableGetProperty(sampleTable,
                                       kQTPropertyClass_SampleTable,
                                       kQTSampleTablePropertyID_MinDisplayOffset,
                                       sizeof(TimeValue64),
                                       &minDisplayOffset,
                                       NULL);
        require_noerr(err, bail);

        trackHelper->minDisplayOffset = minDisplayOffset;

        SInt64 sampleIndex, sampleCount;
        sampleCount = QTSampleTableGetNumberOfSamples(sampleTable);

        for (sampleIndex = 1; sampleIndex <= sampleCount && !isCancelled; sampleIndex++) {
            while ([samplesBuffer count] >= 300) {
                usleep(200);
            }

            TimeValue64 sampleDecodeTime = 0;
            ByteCount sampleDataSize = 0;
            MediaSampleFlags sampleFlags = 0;
            UInt8 *sampleData = NULL;
            TimeValue64 decodeDuration = QTSampleTableGetDecodeDuration(sampleTable, sampleIndex);
            TimeValue64 displayOffset = QTSampleTableGetDisplayOffset(sampleTable, sampleIndex);
            //uint32_t dflags = 0;

            // Get the frame's data size and sample flags.  
            SampleNumToMediaDecodeTime( media, sampleIndex, &sampleDecodeTime, NULL);
            sampleDataSize = QTSampleTableGetDataSizePerSample(sampleTable, sampleIndex);
            sampleFlags = QTSampleTableGetSampleFlags(sampleTable, sampleIndex);
            /*dflags |= (sampleFlags & mediaSampleHasRedundantCoding) ? MP4_SDT_HAS_REDUNDANT_CODING : 0;
            dflags |= (sampleFlags & mediaSampleHasNoRedundantCoding) ? MP4_SDT_HAS_NO_REDUNDANT_CODING : 0;
            dflags |= (sampleFlags & mediaSampleIsDependedOnByOthers) ? MP4_SDT_HAS_DEPENDENTS : 0;
            dflags |= (sampleFlags & mediaSampleIsNotDependedOnByOthers) ? MP4_SDT_HAS_NO_DEPENDENTS : 0;
            dflags |= (sampleFlags & mediaSampleDependsOnOthers) ? MP4_SDT_IS_DEPENDENT : 0;
            dflags |= (sampleFlags & mediaSampleDoesNotDependOnOthers) ? MP4_SDT_IS_INDEPENDENT : 0;
            dflags |= (sampleFlags & mediaSampleEarlierDisplayTimesAllowed) ? MP4_SDT_EARLIER_DISPLAY_TIMES_ALLOWED : 0;*/

            // Load the frame.
            sampleData = malloc(sampleDataSize);
            GetMediaSample2(media, sampleData, sampleDataSize, NULL, sampleDecodeTime,
                            NULL, NULL, NULL, NULL, NULL, 1, NULL, NULL);

            trackHelper->currentSampleId = trackHelper->currentSampleId + 1;
            trackHelper->currentTime = trackHelper->currentTime + decodeDuration;

            MP42SampleBuffer *sample = [[MP42SampleBuffer alloc] init];
            sample->sampleData = sampleData;
            sample->sampleSize = sampleDataSize;
            sample->sampleDuration = decodeDuration;
            sample->sampleOffset = displayOffset -minDisplayOffset;
            sample->sampleTimestamp = trackHelper->currentTime;
            sample->sampleIsSync = !(sampleFlags & mediaSampleNotSync);
            sample->sampleTrackId = track.Id;
            if(track.needConversion)
                sample->sampleSourceTrack = track;

            @synchronized(samplesBuffer) {
                [samplesBuffer addObject:sample];
                [sample release];
            }

            progress = ((trackHelper->currentSampleId / (CGFloat) trackHelper->totalSampleNumber ) * 100 / tracksNumber) +
            (tracksDone / (CGFloat) tracksNumber * 100);
        }

        tracksDone++;

        bail:
        QTSampleTableRelease(sampleTable);
    }

    readerStatus = 1;
    [pool release];
}

- (MP42SampleBuffer*)copyNextSample
{    
    if (samplesBuffer == nil) {
        samplesBuffer = [[NSMutableArray alloc] initWithCapacity:200];
    }    
    
    if (!dataReader && !readerStatus) {
        dataReader = [[NSThread alloc] initWithTarget:self selector:@selector(fillMovieSampleBuffer:) object:self];
        [dataReader start];
    }
    
    while (![samplesBuffer count] && !readerStatus)
        usleep(2000);
    
    if (readerStatus)
        if ([samplesBuffer count] == 0) {
            readerStatus = 0;
            [dataReader release];
            dataReader = nil;
            return nil;
        }
    
    MP42SampleBuffer* sample;
    
    @synchronized(samplesBuffer) {
        sample = [samplesBuffer objectAtIndex:0];
        [sample retain];
        [samplesBuffer removeObjectAtIndex:0];
    }
    
    return sample;
}

- (void)setActiveTrack:(MP42Track *)track {
    if (!activeTracks)
        activeTracks = [[NSMutableArray alloc] init];
    
    [activeTracks addObject:track];
}

- (CGFloat)progress
{
    return progress;
}

- (BOOL)cleanUp:(MP4FileHandle) fileHandle
{
    for (MP42Track * track in activeTracks) {
        Track qtcTrack = [[sourceFile trackWithTrackID:[track sourceId]] quickTimeTrack];

        TimeValue editTrackStart, editTrackDuration;
        TimeValue64 editDisplayStart, trackDuration = 0;
        Fixed editDwell;

        MovTrackHelper * trackHelper;
        trackHelper = track.trackDemuxerHelper;

        // Find the first edit
        // Each edit has a starting track timestamp, a duration in track time, a starting display timestamp and a rate.
        GetTrackNextInterestingTime(qtcTrack, 
                                    nextTimeTrackEdit | nextTimeEdgeOK,
                                    0,
                                    fixed1,
                                    &editTrackStart,
                                    &editTrackDuration);

        while (editTrackDuration > 0) {
            editDisplayStart = TrackTimeToMediaTime(editTrackStart, qtcTrack);
            editTrackDuration = (editTrackDuration / (double)GetMovieTimeScale([sourceFile quickTimeMovie])) * MP4GetTimeScale(fileHandle);
            editDwell = GetTrackEditRate64(qtcTrack, editTrackStart);

            if (trackHelper->minDisplayOffset < 0 && editDisplayStart != -1)
                MP4AddTrackEdit(fileHandle, [track Id], MP4_INVALID_EDIT_ID, editDisplayStart - trackHelper->minDisplayOffset,
                                editTrackDuration, !Fix2X(editDwell));
            else
                MP4AddTrackEdit(fileHandle, [track Id], MP4_INVALID_EDIT_ID, editDisplayStart,
                                editTrackDuration, !Fix2X(editDwell));

            trackDuration += editTrackDuration;
            // Find the next edit
            GetTrackNextInterestingTime(qtcTrack,
                                        nextTimeTrackEdit,
                                        editTrackStart,
                                        fixed1,
                                        &editTrackStart,
                                        &editTrackDuration);
        }

        MP4SetTrackIntegerProperty(fileHandle, [track Id], "tkhd.duration", trackDuration);
    }
    
    return YES;
}

- (void) dealloc
{
    if (dataReader)
        [dataReader release];

	[fileURL release];
    [tracksArray release];

    if (activeTracks)
        [activeTracks release];
    if (samplesBuffer)
        [samplesBuffer release];

    [metadata release];
    [sourceFile release];

    [super dealloc];
}

@end

#endif
