//
//  VideoPlayer.m
//  Vimeo
//
//  Created by Alfred Hanssen on 2/9/14.
//  Copyright (c) 2014-2015 Vimeo (https://vimeo.com)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

#import "VIMVideoPlayer.h"

static const float DefaultPlayableBufferLength = 2.0f;
static const float DefaultVolumeFadeDuration = 1.0f;

NSString * const kVideoPlayerErrorDomain = @"kVideoPlayerErrorDomain";

static void *VideoPlayer_PlayerItemStatusContext = &VideoPlayer_PlayerItemStatusContext;
static void *VideoPlayer_PlayerExternalPlaybackActiveContext = &VideoPlayer_PlayerExternalPlaybackActiveContext;
static void *VideoPlayer_PlayerRateChangedContext = &VideoPlayer_PlayerRateChangedContext;
static void *VideoPlayer_PlayerItemPlaybackLikelyToKeepUp = &VideoPlayer_PlayerItemPlaybackLikelyToKeepUp;
static void *VideoPlayer_PlayerItemPlaybackBufferEmpty = &VideoPlayer_PlayerItemPlaybackBufferEmpty;
static void *VideoPlayer_PlayerItemLoadedTimeRangesContext = &VideoPlayer_PlayerItemLoadedTimeRangesContext;

NSString *const VIMVideoPlayerIsReadyToPlayNotification = @"VIMVideoPlayerIsReadyToPlay";
NSString *const VIMVideoPlayerWillPauseNotification = @"VIMVideoPlayerWillPause";
NSString *const VIMVideoPlayerDidPauseNotification = @"VIMVideoPlayerDidPause";
NSString *const VIMVideoPlayerDidReachEndNotification = @"VIMVideoPlayerDidReachEnd";
NSString *const VIMVideoPlayerTimeDidChangeNotification = @"VIMVideoPlayerTimeDidChange";
NSString *const VIMVideoPlayerLoadedTimeRangeDidChangeNotification = @"VIMVideoPlayerLoadedTimeRangeDidChange";
NSString *const VIMVideoPlayerPlaybackBufferEmptyNotification = @"VIMVideoPlayerPlaybackBufferEmpty";
NSString *const VIMVideoPlayerPlaybackStalledNotification = @"VIMVideoPlayerPlaybackStalled";
NSString *const VIMVideoPlayerPlaybackLikelyToKeepUpNotification = @"VIMVideoPlayerPlaybackLikelyToKeepUp";
NSString *const VIMVideoPlayerDidFailWithErrorNotification = @"VIMVideoPlayerDidFailWithError";
NSString *const VIMVideoPlayerNotificationTimeKey = @"time";
NSString *const VIMVideoPlayerNotificationErrorKey = @"error";
NSString *const VIMVideoPlayerNotificationLoadedDurationKey = @"loadedDuration";

@interface VIMVideoPlayer ()

@property (nonatomic, strong, readwrite) AVPlayer *player;

@property (nonatomic, assign, getter=isPlaying, readwrite) BOOL playing;
@property (nonatomic, assign, getter=isScrubbing) BOOL scrubbing;
@property (nonatomic, assign, getter=isSeeking) BOOL seeking;
@property (nonatomic, assign) BOOL isAtEndTime;
@property (nonatomic, assign) BOOL shouldPlayAfterScrubbing;

@property (nonatomic, assign) float volumeFadeDuration;
@property (nonatomic, assign) float playableBufferLength;

@property (nonatomic, assign) BOOL isTimingUpdateEnabled;
@property (nonatomic, strong) id timeObserverToken;

@property (nonatomic, strong) AVPlayerItem *item;

@end

@implementation VIMVideoPlayer

- (void)dealloc
{
    [self resetPlayerItemIfNecessary];
    
    [self removePlayerObservers];
    
    [self removeTimeObserver];
    
    [self cancelFadeVolume];
}

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _volumeFadeDuration = DefaultVolumeFadeDuration;
        _playableBufferLength = DefaultPlayableBufferLength;
        _timeUpdateInterval = 0.1f;
        
        [self setupPlayer];
        
        [self addPlayerObservers];

        [self setupAudioSession];
    }
    
    return self;
}

#pragma mark - Setup

- (void)setupPlayer
{
    self.player = [[AVPlayer alloc] init];
    
    self.muted = NO;
    self.looping = NO;
    
    self.player.usesExternalPlaybackWhileExternalScreenIsActive = YES;
    
    [self setVolume:1.0f];
    [self enableTimeUpdates];
    [self enableAirplay];
}

- (void)setupAudioSession
{
    NSError *categoryError = nil;
    BOOL success = [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&categoryError];
    if (!success)
    {
        NSLog(@"Error setting audio session category: %@", categoryError);
    }
    
    NSError *activeError = nil;
    success = [[AVAudioSession sharedInstance] setActive:YES error:&activeError];
    if (!success)
    {
        NSLog(@"Error setting audio session active: %@", activeError);
    }
}

#pragma mark - Public API

- (void)setURL:(NSURL *)URL
{
    if (URL == nil)
    {
        return;
    }

    [self resetPlayerItemIfNecessary];

    AVPlayerItem *playerItem = [[AVPlayerItem alloc] initWithURL:URL];
    if (!playerItem)
    {
        [self reportUnableToCreatePlayerItem];
        
        return;
    }

    [self preparePlayerItem:playerItem];
}

- (void)setPlayerItem:(AVPlayerItem *)playerItem
{
    if (playerItem == nil)
    {
        return;
    }
    
    [self resetPlayerItemIfNecessary];

    [self preparePlayerItem:playerItem];
}

- (void)setAsset:(AVAsset *)asset
{
    if (asset == nil)
    {
        return;
    }

    [self resetPlayerItemIfNecessary];
    
    AVPlayerItem *playerItem = [[AVPlayerItem alloc] initWithAsset: asset];
    
    if (!playerItem)
    {
        [self reportUnableToCreatePlayerItem];
        
        return;
    }
    
    [self preparePlayerItem:playerItem];
}

#pragma mark - Accessor Overrides

- (void)setMuted:(BOOL)muted
{
    if (self.player)
    {
        self.player.muted = muted;
    }
}

- (BOOL)isMuted
{
    return self.player.isMuted;
}

- (void)setTimeUpdateInterval:(NSTimeInterval)timeUpdateInterval
{
    if (timeUpdateInterval <= 0) {
        _timeUpdateInterval = 0;
        [self disableTimeUpdates];
    } else {
        _timeUpdateInterval = timeUpdateInterval;
        [self disableTimeUpdates];
        [self enableTimeUpdates];
    }
}

#pragma mark - Playback

- (void)play
{
    if (self.player.currentItem == nil)
    {
        return;
    }
    
    self.playing = YES;
   
    if ([self.player.currentItem status] == AVPlayerItemStatusReadyToPlay)
    {
        if ([self isAtEndTime])
        {
            [self restart];
        }
        else
        {
            [self.player play];
        }
    }
}

- (void)pause
{
    if (!self.isPlaying && self.player.rate == 0.0f) {
        return;
    }

    if ([self.delegate respondsToSelector:@selector(videoPlayerWillPause:)]) {
        [self.delegate videoPlayerWillPause:self];
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:VIMVideoPlayerWillPauseNotification object:self];

    self.playing = NO;
    [self.player pause];

    if ([self.delegate respondsToSelector:@selector(videoPlayerDidPause:)]) {
        [self.delegate videoPlayerDidPause:self];
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:VIMVideoPlayerDidPauseNotification object:self];
}

- (void)seekToTime:(float)time
{
    if (_seeking)
    {
        return;
    }
    
    if (self.player)
    {
        CMTime cmTime = CMTimeMakeWithSeconds(time, self.player.currentTime.timescale);
        
        if (CMTIME_IS_INVALID(cmTime) || self.player.currentItem.status != AVPlayerStatusReadyToPlay)
        {
            return;
        }
        
        _seeking = YES;
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            
            [self.player seekToTime:cmTime toleranceBefore:CMTimeMakeWithSeconds(1, NSEC_PER_SEC) toleranceAfter:CMTimeMakeWithSeconds(1, NSEC_PER_SEC) completionHandler:^(BOOL finished) {
                
                _isAtEndTime = NO;
                _seeking = NO;

                if (finished)
                {
                    _scrubbing = NO;
                }
                
            }];
        });
    }
}

- (void)reset
{
    [self pause];
    [self resetPlayerItemIfNecessary];
}

#pragma mark - Airplay

- (void)enableAirplay
{
    if (self.player)
    {
        self.player.allowsExternalPlayback = YES;
    }
}

- (void)disableAirplay
{
    if (self.player)
    {
        self.player.allowsExternalPlayback = NO;
    }
}

- (BOOL)isAirplayEnabled
{
    return (self.player && self.player.allowsExternalPlayback);
}

#pragma mark - Scrubbing

- (void)startScrubbing
{
    self.scrubbing = YES;
    
    if (self.isPlaying)
    {
        self.shouldPlayAfterScrubbing = YES;

        [self pause];
    }
}

- (void)scrub:(float)time
{
    if (self.isScrubbing == NO)
    {
        [self startScrubbing];
    }
    
    [self.player.currentItem cancelPendingSeeks];
    
    [self seekToTime:time];
}

- (void)stopScrubbing
{
    if (self.shouldPlayAfterScrubbing)
    {
        [self play];

        self.shouldPlayAfterScrubbing = NO;
    }

    self.scrubbing = NO;
}

#pragma mark - Time Updates

- (void)enableTimeUpdates
{
    self.isTimingUpdateEnabled = YES;
    
    [self addTimeObserver];
}

- (void)disableTimeUpdates
{
    self.isTimingUpdateEnabled = NO;
    
    [self removeTimeObserver];
}

#pragma mark - Volume

- (void)setVolume:(float)volume
{
    [self cancelFadeVolume];
    
    self.player.volume = volume;
}

- (void)cancelFadeVolume
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fadeInVolume) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fadeOutVolume) object:nil];
}

- (void)fadeInVolume
{
    if (self.player == nil)
    {
        return;
    }
    
    [self cancelFadeVolume];
    
    if (self.player.volume >= 1.0f - 0.01f)
    {
        self.player.volume = 1.0f;
    }
    else
    {
        self.player.volume += 1.0f/10.0f;
        
        [self performSelector:@selector(fadeInVolume) withObject:nil afterDelay:self.volumeFadeDuration/10.0f];
    }
}

- (void)fadeOutVolume
{
    if (self.player == nil)
    {
        return;
    }
    
    [self cancelFadeVolume];
    
    if (self.player.volume <= 0.01f)
    {
        self.player.volume = 0.0f;
    }
    else
    {
        self.player.volume -= 1.0f/10.0f;
        
        [self performSelector:@selector(fadeOutVolume) withObject:nil afterDelay:self.volumeFadeDuration/10.0f];
    }
}

#pragma mark - Private API

- (void)reportUnableToCreatePlayerItem
{
    NSError *error = [NSError errorWithDomain:kVideoPlayerErrorDomain
                                         code:0
                                     userInfo:@{NSLocalizedDescriptionKey : @"Unable to create AVPlayerItem."}];
    if ([self.delegate respondsToSelector:@selector(videoPlayer:didFailWithError:)])
    {
        [self.delegate videoPlayer:self didFailWithError:error];
    }

    NSDictionary<NSString *, id> *userInfo = @{
        VIMVideoPlayerNotificationErrorKey: error,
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:VIMVideoPlayerDidFailWithErrorNotification object:self userInfo:userInfo];
}

- (void)resetPlayerItemIfNecessary
{
    if (self.item)
    {
        [self removePlayerItemObservers:self.item];
        
        [self.player replaceCurrentItemWithPlayerItem:nil];
        
        self.item = nil;
    }
    
    _volumeFadeDuration = DefaultVolumeFadeDuration;
    _playableBufferLength = DefaultPlayableBufferLength;
    
    _playing = NO;
    _isAtEndTime = NO;
    _scrubbing = NO;
}

- (void)preparePlayerItem:(AVPlayerItem *)playerItem
{
    NSParameterAssert(playerItem);
    
    self.item = playerItem;
    
    [self addPlayerItemObservers:playerItem];
    
    [self.player replaceCurrentItemWithPlayerItem:playerItem];
}

- (void)restart
{
    [self.player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
        
        if (finished)
        {
            _isAtEndTime = NO;
         
            if (self.isPlaying)
            {
                [self play];
            }
        }
        
    }];
}

- (BOOL)isAtEndTime // TODO: this is a fucked up override, seems like something could be wrong [AH]
{
    if (self.player && self.player.currentItem)
    {
        if (_isAtEndTime)
        {
            return _isAtEndTime;
        }
        
        float currentTime = 0.0f;
        if (CMTIME_IS_INVALID(self.player.currentTime) == NO)
        {
            currentTime = CMTimeGetSeconds(self.player.currentTime);
        }
        
        float videoDuration = 0.0f;
        if (CMTIME_IS_INVALID(self.player.currentItem.duration) == NO)
        {
            videoDuration = CMTimeGetSeconds(self.player.currentItem.duration);
        }
        
        if (currentTime > 0.0f && videoDuration > 0.0f)
        {
            if (fabs(currentTime - videoDuration) <= 0.01f)
            {
                return YES;
            }
        }
    }
    
    return NO;
}

- (float)calcLoadedDuration
{
    float loadedDuration = 0.0f;
    
    if (self.player && self.player.currentItem)
    {
        NSArray *loadedTimeRanges = self.player.currentItem.loadedTimeRanges;
        
        if (loadedTimeRanges && [loadedTimeRanges count])
        {
            CMTimeRange timeRange = [[loadedTimeRanges firstObject] CMTimeRangeValue];
            float startSeconds = CMTimeGetSeconds(timeRange.start);
            float durationSeconds = CMTimeGetSeconds(timeRange.duration);
            
            loadedDuration = startSeconds + durationSeconds;
        }
    }
    
    return loadedDuration;
}

#pragma mark - Player Observers

- (void)addPlayerObservers
{
    [self.player addObserver:self
                  forKeyPath:NSStringFromSelector(@selector(isExternalPlaybackActive))
                     options:NSKeyValueObservingOptionNew
                     context:VideoPlayer_PlayerExternalPlaybackActiveContext];
    
    [self.player addObserver:self
                  forKeyPath:NSStringFromSelector(@selector(rate))
                     options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                     context:VideoPlayer_PlayerRateChangedContext];
}

- (void)removePlayerObservers
{
    @try
    {
        [self.player removeObserver:self
                         forKeyPath:NSStringFromSelector(@selector(isExternalPlaybackActive))
                            context:VideoPlayer_PlayerExternalPlaybackActiveContext];
    }
    @catch (NSException *exception)
    {
        NSLog(@"Exception removing observer: %@", exception);
    }
    
    @try
    {
        [self.player removeObserver:self
                         forKeyPath:NSStringFromSelector(@selector(rate))
                            context:VideoPlayer_PlayerRateChangedContext];
    }
    @catch (NSException *exception)
    {
        NSLog(@"Exception removing observer: %@", exception);
    }
}

#pragma mark - PlayerItem Observers

- (void)addPlayerItemObservers:(AVPlayerItem *)playerItem
{
    [playerItem addObserver:self
                 forKeyPath:NSStringFromSelector(@selector(status))
                    options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew
                    context:VideoPlayer_PlayerItemStatusContext];
    
    [playerItem addObserver:self
                 forKeyPath:NSStringFromSelector(@selector(isPlaybackLikelyToKeepUp))
                    options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                    context:VideoPlayer_PlayerItemPlaybackLikelyToKeepUp];
    
    [playerItem addObserver:self
                 forKeyPath:NSStringFromSelector(@selector(isPlaybackBufferEmpty))
                    options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                    context:VideoPlayer_PlayerItemPlaybackBufferEmpty];
    
    [playerItem addObserver:self
                 forKeyPath:NSStringFromSelector(@selector(loadedTimeRanges))
                    options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                    context:VideoPlayer_PlayerItemLoadedTimeRangesContext];

    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    [notificationCenter addObserver:self
                           selector:@selector(playerItemDidPlayToEndTime:)
                               name:AVPlayerItemDidPlayToEndTimeNotification
                             object:playerItem];
    [notificationCenter addObserver:self
                           selector:@selector(playerItemPlaybackStalled:)
                               name:AVPlayerItemPlaybackStalledNotification
                             object:playerItem];
}

- (void)removePlayerItemObservers:(AVPlayerItem *)playerItem
{
    [playerItem cancelPendingSeeks];
    
    @try
    {
        [playerItem removeObserver:self
                        forKeyPath:NSStringFromSelector(@selector(status))
                           context:VideoPlayer_PlayerItemStatusContext];
    }
    @catch (NSException *exception)
    {
        NSLog(@"Exception removing observer: %@", exception);
    }

    @try
    {
        [playerItem removeObserver:self
                        forKeyPath:NSStringFromSelector(@selector(isPlaybackLikelyToKeepUp))
                           context:VideoPlayer_PlayerItemPlaybackLikelyToKeepUp];
    }
    @catch (NSException *exception)
    {
        NSLog(@"Exception removing observer: %@", exception);
    }

    @try
    {
        [playerItem removeObserver:self
                        forKeyPath:NSStringFromSelector(@selector(isPlaybackBufferEmpty))
                           context:VideoPlayer_PlayerItemPlaybackBufferEmpty];
    }
    @catch (NSException *exception)
    {
        NSLog(@"Exception removing observer: %@", exception);
    }

    @try
    {
        [playerItem removeObserver:self
                        forKeyPath:NSStringFromSelector(@selector(loadedTimeRanges))
                           context:VideoPlayer_PlayerItemLoadedTimeRangesContext];
    }
    @catch (NSException *exception)
    {
        NSLog(@"Exception removing observer: %@", exception);
    }

    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    [notificationCenter removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:playerItem];
    [notificationCenter removeObserver:self name:AVPlayerItemPlaybackStalledNotification object:playerItem];
}

#pragma mark - Time Observer

- (void)addTimeObserver
{
    if (self.timeObserverToken || self.player == nil)
    {
        return;
    }
    
    __weak typeof (self) weakSelf = self;
    self.timeObserverToken = [self.player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(self.timeUpdateInterval, NSEC_PER_SEC) queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
        
        __strong typeof (self) strongSelf = weakSelf;
        if (!strongSelf)
        {
            return;
        }

        if ([strongSelf.delegate respondsToSelector:@selector(videoPlayer:timeDidChange:)])
        {
            [strongSelf.delegate videoPlayer:strongSelf timeDidChange:time];
        }
        NSDictionary<NSString *, id> *userInfo = @{
            VIMVideoPlayerNotificationTimeKey: @(CMTimeGetSeconds(time)),
        };
        [[NSNotificationCenter defaultCenter] postNotificationName:VIMVideoPlayerTimeDidChangeNotification object:strongSelf userInfo:userInfo];
    }];
}

- (void)removeTimeObserver
{
    if (self.timeObserverToken == nil)
    {
        return;
    }
 
    if (self.player)
    {
        [self.player removeTimeObserver:self.timeObserverToken];
    }
    
    self.timeObserverToken = nil;
}

#pragma mark - Observer Response

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context == VideoPlayer_PlayerRateChangedContext)
    {
        if (self.isScrubbing == NO && self.isPlaying && self.player.rate == 0.0f)
        {
            // TODO: Show loading indicator
        }
    }
    else if (context == VideoPlayer_PlayerItemStatusContext)
    {
        AVPlayerStatus newStatus = [[change objectForKey:NSKeyValueChangeNewKey] integerValue];
        AVPlayerStatus oldStatus = [[change objectForKey:NSKeyValueChangeOldKey] integerValue];
        
        if (newStatus != oldStatus)
        {
            switch (newStatus)
            {
                case AVPlayerItemStatusUnknown:
                {
                    NSLog(@"Video player Status Unknown");
                    break;
                }
                case AVPlayerItemStatusReadyToPlay:
                {
                    dispatch_async(dispatch_get_main_queue(), ^
                    {
                        if ([self.delegate respondsToSelector:@selector(videoPlayerIsReadyToPlayVideo:)])
                        {
                            [self.delegate videoPlayerIsReadyToPlayVideo:self];
                        }
                        [[NSNotificationCenter defaultCenter] postNotificationName:VIMVideoPlayerIsReadyToPlayNotification object:self];
                    });
                    
                    if (self.isPlaying)
                    {
                        [self play];
                    }
                    
                    break;
                }
                case AVPlayerItemStatusFailed:
                {
                    NSLog(@"Video player Status Failed: player item error = %@", self.player.currentItem.error);
                    NSLog(@"Video player Status Failed: player error = %@", self.player.error);
                    
                    // First, try to use the player error if it exists

                    NSError *error = self.player.error;
                    
                    // Otherwise try to use the current item's error
                    
                    if (!error)
                    {
                        error = self.player.currentItem.error;
                    }
                    
                    // If there's a more specific underlyng error, use that
                    
                    NSError *underlyingError = [error.userInfo objectForKey:NSUnderlyingErrorKey];
                    
                    if (underlyingError)
                    {
                        error = underlyingError;
                    }

                    // Finally, construct our own as a last resort
                    
                    if (!error)
                    {
                        error = [NSError errorWithDomain:kVideoPlayerErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey : @"unknown player error, status == AVPlayerItemStatusFailed"}];
                    }
                    
                    [self reset];

                    dispatch_async(dispatch_get_main_queue(), ^
                    {
                        if ([self.delegate respondsToSelector:@selector(videoPlayer:didFailWithError:)])
                        {
                            [self.delegate videoPlayer:self didFailWithError:error];
                        }

                        NSDictionary<NSString *, id> *userInfo = @{
                            VIMVideoPlayerNotificationErrorKey: error,
                        };
                        [[NSNotificationCenter defaultCenter] postNotificationName:VIMVideoPlayerDidFailWithErrorNotification object:self userInfo:userInfo];
                    });
                    
                    break;
                }
            }
        }
        else if (newStatus == AVPlayerItemStatusReadyToPlay)
        {
            // When playback resumes after a buffering event, a new ReadyToPlay status is set [RH]
            dispatch_async(dispatch_get_main_queue(), ^
            {
                if ([self.delegate respondsToSelector:@selector(videoPlayerPlaybackLikelyToKeepUp:)])
                {
                    [self.delegate videoPlayerPlaybackLikelyToKeepUp:self];
                }
                [[NSNotificationCenter defaultCenter] postNotificationName:VIMVideoPlayerPlaybackLikelyToKeepUpNotification object:self];
            });
        }
    }
    else if (context == VideoPlayer_PlayerItemPlaybackBufferEmpty)
    {
        if (self.player.currentItem.playbackBufferEmpty)
        {
            if (self.isPlaying)
            {
                dispatch_async(dispatch_get_main_queue(), ^
                {
                    if ([self.delegate respondsToSelector:@selector(videoPlayerPlaybackBufferEmpty:)])
                    {
                        [self.delegate videoPlayerPlaybackBufferEmpty:self];
                    }
                    [[NSNotificationCenter defaultCenter] postNotificationName:VIMVideoPlayerPlaybackBufferEmptyNotification object:self];
                });
            }
        }
    }
    else if (context == VideoPlayer_PlayerItemPlaybackLikelyToKeepUp)
    {
        if (self.player.currentItem.playbackLikelyToKeepUp)
        {
            // TODO: Hide loading indicator

            if (self.isScrubbing == NO && self.isPlaying && self.player.rate == 0.0f)
            {
                [self play];
            }
        }
    }
    else if (context == VideoPlayer_PlayerItemLoadedTimeRangesContext)
    {
        float loadedDuration = [self calcLoadedDuration];

        if (self.isScrubbing == NO && self.isPlaying && self.player.rate == 0.0f)
        {
            if (loadedDuration >= CMTimeGetSeconds(self.player.currentTime) + self.playableBufferLength)
            {
                self.playableBufferLength *= 2;

                if (self.playableBufferLength > 64)
                {
                    self.playableBufferLength = 64;
                }
                
                [self play];
            }
        }
        
        if ([self.delegate respondsToSelector:@selector(videoPlayer:loadedTimeRangeDidChange:)])
        {
            [self.delegate videoPlayer:self loadedTimeRangeDidChange:loadedDuration];
        }
        NSDictionary<NSString *, id> *userInfo = @{
            VIMVideoPlayerNotificationLoadedDurationKey: @(loadedDuration),
        };
        [[NSNotificationCenter defaultCenter] postNotificationName:VIMVideoPlayerLoadedTimeRangeDidChangeNotification object:self userInfo:userInfo];
    }
    else if (context == VideoPlayer_PlayerExternalPlaybackActiveContext)
    {
        
    }
    else
    {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)playerItemDidPlayToEndTime:(NSNotification *)notification
{
    if (notification.object != self.player.currentItem)
    {
        return;
    }
    
    if (self.isLooping)
    {
        [self restart];
    }
    else
    {
        _isAtEndTime = YES;
        self.playing = NO;
    }

    if ([self.delegate respondsToSelector:@selector(videoPlayerDidReachEnd:)])
    {
        [self.delegate videoPlayerDidReachEnd:self];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:VIMVideoPlayerDidReachEndNotification object:self];
}

- (void)playerItemPlaybackStalled:(NSNotification *)notification
{
    if (notification.object != self.player.currentItem)
    {
        return;
    }

    // NOTE: Should we change the `playing` status?
    if ([self.delegate respondsToSelector:@selector(videoPlayerPlaybackStalled:)])
    {
        [self.delegate videoPlayerPlaybackStalled:self];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:VIMVideoPlayerPlaybackStalledNotification object:self];
}

@end
