#import "RZVideoCompressor.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

@implementation RZVideoCompressor

static NSError *RZVideoError(NSString *msg) {
    return [NSError errorWithDomain:@"RZVideo" code:1 userInfo:@{NSLocalizedDescriptionKey: msg}];
}

+ (void)compress:(NSURL *)src to:(NSString *)dst progress:(void (^)(double))progress done:(void (^)(NSError *))done {
    void (^finish)(NSError *) = ^(NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(e); });
    };
    dispatch_queue_t q = dispatch_queue_create("gm.video", DISPATCH_QUEUE_SERIAL);
    dispatch_async(q, ^{
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:src options:nil];
        NSArray *vts = [asset tracksWithMediaType:AVMediaTypeVideo];
        NSArray *ats = [asset tracksWithMediaType:AVMediaTypeAudio];
        if (!vts.count) return finish(RZVideoError(@"không có hình"));
        AVAssetTrack *vt = [vts objectAtIndex:0];
        AVAssetTrack *at = ats.count ? [ats objectAtIndex:0] : nil;
        double total = CMTimeGetSeconds(asset.duration);

        NSError *err = nil;
        AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
        if (!reader) return finish(err);
        AVAssetReaderTrackOutput *vo = [AVAssetReaderTrackOutput
            assetReaderTrackOutputWithTrack:vt
                             outputSettings:@{(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey:
                                                  @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)}];
        vo.alwaysCopiesSampleData = NO;
        [reader addOutput:vo];
        AVAssetReaderTrackOutput *ao = nil;
        int channels = 1;
        double rate = 44100;
        if (at) {
            CMFormatDescriptionRef fd = (__bridge CMFormatDescriptionRef)[at.formatDescriptions lastObject];
            const AudioStreamBasicDescription *asbd = fd ? CMAudioFormatDescriptionGetStreamBasicDescription(fd) : NULL;
            if (asbd) {
                channels = MIN(2, MAX(1, (int)asbd->mChannelsPerFrame));
                if (asbd->mSampleRate >= 8000) rate = MIN(48000, asbd->mSampleRate);
            }
            ao = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:at
                                                            outputSettings:@{AVFormatIDKey: @(kAudioFormatLinearPCM)}];
            ao.alwaysCopiesSampleData = NO;
            [reader addOutput:ao];
        }

        [[NSFileManager defaultManager] removeItemAtPath:dst error:NULL];
        AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:dst] fileType:AVFileTypeMPEG4 error:&err];
        if (!writer) return finish(err);
        writer.shouldOptimizeForNetworkUse = YES;
        // Cạnh dài ≤ 640, số chẵn (H.264 4:2:0); giữ đúng tỉ lệ (640×360 cho video 16:9)
        CGSize n = vt.naturalSize;
        CGFloat k = MIN(1.0, 640.0 / MAX(n.width, n.height));
        int w = MAX(16, (int)lround(n.width * k / 2) * 2), h = MAX(16, (int)lround(n.height * k / 2) * 2);
        AVAssetWriterInput *vi = [AVAssetWriterInput
            assetWriterInputWithMediaType:AVMediaTypeVideo
                           outputSettings:@{
                               AVVideoCodecKey: AVVideoCodecH264,
                               AVVideoWidthKey: @(w),
                               AVVideoHeightKey: @(h),
                               AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
                               AVVideoCompressionPropertiesKey: @{
                                   AVVideoAverageBitRateKey: @(1200 * 1000),
                                   AVVideoProfileLevelKey: AVVideoProfileLevelH264Baseline30,
                                   AVVideoMaxKeyFrameIntervalKey: @60,
                               },
                           }];
        vi.transform = vt.preferredTransform;  // giữ hướng quay (video dọc)
        vi.expectsMediaDataInRealTime = NO;
        [writer addInput:vi];
        AVAssetWriterInput *ai = nil;
        if (ao) {
            AudioChannelLayout acl;
            memset(&acl, 0, sizeof(acl));
            acl.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo;
            ai = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                    outputSettings:@{
                                                        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
                                                        AVNumberOfChannelsKey: @(channels),
                                                        AVSampleRateKey: @(rate),
                                                        AVEncoderBitRateKey: @(64000 * channels),
                                                        AVChannelLayoutKey: [NSData dataWithBytes:&acl length:sizeof(acl)],
                                                    }];
            ai.expectsMediaDataInRealTime = NO;
            [writer addInput:ai];
        }

        if (![writer startWriting]) return finish(writer.error);
        if (![reader startReading]) {
            [writer cancelWriting];
            return finish(reader.error);
        }
        [writer startSessionAtSourceTime:kCMTimeZero];

        dispatch_group_t g = dispatch_group_create();
        void (^pump)(AVAssetWriterInput *, AVAssetReaderOutput *, BOOL) =
            ^(AVAssetWriterInput *in, AVAssetReaderOutput *out, BOOL isVideo) {
                __block BOOL ended = NO;
                dispatch_group_enter(g);
                dispatch_queue_t iq = dispatch_queue_create(isVideo ? "gm.video.v" : "gm.video.a", DISPATCH_QUEUE_SERIAL);
                __block double last = -1;
                [in requestMediaDataWhenReadyOnQueue:iq usingBlock:^{
                    while (!ended && in.isReadyForMoreMediaData) {
                        CMSampleBufferRef sb = reader.status == AVAssetReaderStatusReading ? [out copyNextSampleBuffer] : NULL;
                        BOOL ok = sb != NULL;
                        if (sb) {
                            if (isVideo && progress && total > 0) {
                                double p = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)) / total;
                                if (p - last >= 0.02) {
                                    last = p;
                                    dispatch_async(dispatch_get_main_queue(), ^{ progress(MIN(1.0, p)); });
                                }
                            }
                            ok = [in appendSampleBuffer:sb];
                            CFRelease(sb);
                        }
                        if (!ok) {
                            ended = YES;
                            [in markAsFinished];
                            dispatch_group_leave(g);
                        }
                    }
                }];
            };
        pump(vi, vo, YES);
        if (ai) pump(ai, ao, NO);
        dispatch_group_wait(g, DISPATCH_TIME_FOREVER);

        if (reader.status == AVAssetReaderStatusFailed || writer.status == AVAssetWriterStatusFailed) {
            NSError *e = writer.error ?: reader.error;
            [reader cancelReading];
            [writer cancelWriting];
            return finish(e ?: RZVideoError(@"nén lỗi"));
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        // finishWritingWithCompletionHandler: chỉ có từ iOS 6 — bản đồng bộ chạy được cả iOS 5 (đang ở hàng nền)
        BOOL ok = [writer finishWriting];
#pragma clang diagnostic pop
        finish(ok ? nil : (writer.error ?: RZVideoError(@"ghi tệp lỗi")));
    });
}

@end
