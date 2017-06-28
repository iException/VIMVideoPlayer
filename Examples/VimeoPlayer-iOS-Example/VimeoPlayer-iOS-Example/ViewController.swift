//
//  ViewController.swift
//  VIMVideoPlayer-iOS-Example
//
//  Created by King, Gavin on 3/9/16.
//  Copyright © 2016 Gavin King. All rights reserved.
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

import UIKit

class ViewController: UIViewController, VIMVideoPlayerViewDelegate
{
    @IBOutlet weak var videoPlayerView: VIMVideoPlayerView!
    @IBOutlet weak var slider: UISlider!
    
    fileprivate var isScrubbing = false
    
    override func viewDidLoad()
    {
        super.viewDidLoad()
        
        self.setupVideoPlayerView()
        self.setupSlider()
    }
    
    // MARK: Setup
    
    fileprivate func setupVideoPlayerView()
    {
        self.videoPlayerView.player.isLooping = true
        self.videoPlayerView.player.disableAirplay()
        self.videoPlayerView.setVideoFillMode(AVLayerVideoGravityResizeAspectFill)
        
        self.videoPlayerView.delegate = self
        
        if let path = Bundle.main.path(forResource: "waterfall", ofType: "mp4")
        {
            self.videoPlayerView.player.setURL(URL(fileURLWithPath: path))
        }
        else
        {
            assertionFailure("Video file not found!")
        }
    }
    
    fileprivate func setupSlider()
    {
        self.slider.addTarget(self, action: #selector(ViewController.scrubbingDidStart), for: UIControlEvents.touchDown)
        self.slider.addTarget(self, action: #selector(ViewController.scrubbingDidChange), for: UIControlEvents.valueChanged)
        self.slider.addTarget(self, action: #selector(ViewController.scrubbingDidEnd), for: UIControlEvents.touchUpInside)
        self.slider.addTarget(self, action: #selector(ViewController.scrubbingDidEnd), for: UIControlEvents.touchUpOutside)
    }
    
    // MARK: Actions
    
    @IBAction func didTapPlayPauseButton(_ sender: UIButton)
    {
        if self.videoPlayerView.player.isPlaying
        {
            sender.isSelected = true
            
            self.videoPlayerView.player.pause()
        }
        else
        {
            sender.isSelected = false
            
            self.videoPlayerView.player.play()
        }
    }
    
    // MARK: Scrubbing Actions
    
    func scrubbingDidStart()
    {
        self.isScrubbing = true
        
        self.videoPlayerView.player.startScrubbing()
    }
    
    func scrubbingDidChange()
    {
        guard let duration = self.videoPlayerView.player.player.currentItem?.duration, self.isScrubbing == true else
        {
            return
        }
        
        let time = Float(CMTimeGetSeconds(duration)) * self.slider.value
        
        self.videoPlayerView.player.scrub(time)
    }
    
    func scrubbingDidEnd()
    {
        self.videoPlayerView.player.stopScrubbing()
        
        self.isScrubbing = false
    }
    
    // MARK: VIMVideoPlayerViewDelegate
    
    func videoPlayerViewIsReady(toPlayVideo videoPlayerView: VIMVideoPlayerView?)
    {
        self.videoPlayerView.player.play()
    }
    
    func videoPlayerView(_ videoPlayerView: VIMVideoPlayerView!, timeDidChange cmTime: CMTime)
    {
        guard let duration = self.videoPlayerView.player.player.currentItem?.duration, self.isScrubbing == false else
        {
            return
        }
        
        let durationInSeconds = Float(CMTimeGetSeconds(duration))
        let timeInSeconds = Float(CMTimeGetSeconds(cmTime))
        
        self.slider.value = timeInSeconds / durationInSeconds
    }
}
