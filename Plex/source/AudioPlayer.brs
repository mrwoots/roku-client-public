'**********************************************************
'**  Modified beyond recognition but originally based on:
'**  Audio Player Example Application - Audio Playback
'**  November 2009
'**  Copyright (c) 2009 Roku Inc. All Rights Reserved.
'**********************************************************

Function AudioPlayer()
    ' Unlike just about everything else, the audio player isn't a Screen.
    ' So we'll wrap the Roku audio player similarly, but not quite in the
    ' same way.

    if m.AudioPlayer = invalid then
        obj = CreateObject("roAssociativeArray")

        obj.Port = GetViewController().GlobalMessagePort

        ' We need a ScreenID property in order to use the view controller for timers
        obj.ScreenID = -1

        obj.HandleMessage = audioPlayerHandleMessage
        obj.Cleanup = audioPlayerCleanup

        obj.Play = audioPlayerPlay
        obj.Pause = audioPlayerPause
        obj.Resume = audioPlayerResume
        obj.Stop = audioPlayerStop
        obj.Seek = audioPlayerSeek
        obj.Next = audioPlayerNext
        obj.Prev = audioPlayerPrev

        obj.player = CreateObject("roAudioPlayer")
        obj.player.SetMessagePort(obj.Port)

        obj.Context = invalid
        obj.CurIndex = invalid
        obj.ContextScreenID = invalid
        obj.SetContext = audioPlayerSetContext

        obj.ShowContextMenu = audioPlayerShowContextMenu

        obj.PlayThemeMusic = audioPlayerPlayThemeMusic

        obj.IsPlaying = false
        obj.IsPaused = false

        obj.Repeat = 0
        obj.SetRepeat = audioPlayerSetRepeat
        NowPlayingManager().timelines["music"].attrs["repeat"] = "0"

        obj.IsShuffled = false
        obj.SetShuffle = audioPlayerSetShuffle
        NowPlayingManager().timelines["music"].attrs["shuffle"] = "0"

        obj.playbackTimer = createTimer()
        obj.playbackOffset = 0
        obj.GetPlaybackProgress = audioPlayerGetPlaybackProgress

        obj.UpdateNowPlaying = audioPlayerUpdateNowPlaying
        obj.OnTimerExpired = audioPlayerOnTimerExpired

        obj.IgnoreTimelines = false
        obj.timelineTimer = createTimer()
        obj.timelineTimer.Name = "timeline"
        obj.timelineTimer.SetDuration(1000, true)
        obj.timelineTimer.Active = false
        GetViewController().AddTimer(obj.timelineTimer, obj)

        ' Singleton
        m.AudioPlayer = obj
    end if

    return m.AudioPlayer
End Function

Function audioPlayerHandleMessage(msg) As Boolean
    handled = false

    if type(msg) = "roAudioPlayerEvent" then
        handled = true
        item = m.Context[m.CurIndex]

        if msg.isRequestSucceeded() then
            Debug("Playback of single song completed")

            if item.ratingKey <> invalid then
                Debug("Scrobbling audio track -> " + tostr(item.ratingKey))
                item.Server.Scrobble(item.ratingKey, item.mediaContainerIdentifier)
            end if

            ' Send an analytics event, but not for theme music
            if m.ContextScreenID <> invalid then
                amountPlayed = m.GetPlaybackProgress()
                Debug("Sending analytics event, appear to have listened to audio for " + tostr(amountPlayed) + " seconds")
                AnalyticsTracker().TrackEvent("Playback", firstOf(item.ContentType, "track"), tostr(item.mediaContainerIdentifier), amountPlayed)
            end if

            if m.Repeat <> 1 then
                maxIndex = m.Context.Count() - 1
                newIndex = m.CurIndex + 1
                if newIndex > maxIndex then newIndex = 0
                m.CurIndex = newIndex
            end if
        else if msg.isRequestFailed() then
            Debug("Audio playback failed")
            m.IgnoreTimelines = false
            maxIndex = m.Context.Count() - 1
            newIndex = m.CurIndex + 1
            if newIndex > maxIndex then newIndex = 0
            m.CurIndex = newIndex
        else if msg.isListItemSelected() then
            Debug("Starting to play track: " + tostr(item.Url))
            m.IgnoreTimelines = false
            m.IsPlaying = true
            m.IsPaused = false
            m.playbackOffset = 0
            m.playbackTimer.Mark()
            GetViewController().DestroyGlitchyScreens()

            if m.Repeat = 1 then
                m.player.SetNext(m.CurIndex)
            end if

            if m.Context.Count() > 1 then
                NowPlayingManager().SetControllable("music", "skipPrevious", (m.CurIndex > 0 OR m.Repeat = 2))
                NowPlayingManager().SetControllable("music", "skipNext", (m.CurIndex < m.Context.Count() - 1 OR m.Repeat = 2))
            end if
        else if msg.isStatusMessage() then
            'Debug("Audio player status: " + tostr(msg.getMessage()))
        else if msg.isFullResult() then
            Debug("Playback of entire audio list finished")
            m.Stop()

            if item.Url = "" then
                ' TODO(schuyler): Show something more useful, especially once
                ' there's a server version that transcodes audio.
                dialog = createBaseDialog()
                dialog.Title = "Content Unavailable"
                dialog.Text = "We're unable to play this audio format."
                dialog.Show()
            end if
        else if msg.isPartialResult() then
            Debug("isPartialResult")
        else if msg.isPaused() then
            Debug("Stream paused by user")
            m.IsPlaying = false
            m.IsPaused = true
            m.playbackOffset = m.playbackOffset + m.playbackTimer.GetElapsedSeconds()
            m.playbackTimer.Mark()
        else if msg.isResumed() then
            Debug("Stream resumed by user")
            m.IsPlaying = true
            m.IsPaused = false
            m.playbackTimer.Mark()
        end if

        m.UpdateNowPlaying()
    end if

    return handled
End Function

Sub audioPlayerCleanup()
    m.Stop()
    m.timelineTimer = invalid
    fn = function() :m.AudioPlayer = invalid :end function
    fn()
End Sub

Sub audioPlayerPlay()
    if m.Context <> invalid then
        m.player.Play()
    end if
End Sub

Sub audioPlayerPause()
    if m.Context <> invalid then
        m.player.Pause()
    end if
End Sub

Sub audioPlayerResume()
    if m.Context <> invalid then
        m.player.Resume()
    end if
End Sub

Sub audioPlayerStop()
    if m.Context <> invalid then
        m.player.Stop()
        m.player.SetNext(m.CurIndex)
        m.IsPlaying = false
        m.IsPaused = false
    end if
End Sub

Sub audioPlayerSeek(offset, relative=false)
    if relative then
        if m.IsPlaying then
            offset = offset + (1000 * m.GetPlaybackProgress())
        else if m.IsPaused then
            offset = offset + (1000 * m.playbackOffset)
        end if

        if offset < 0 then offset = 0
    end if

    if m.IsPlaying then
        m.playbackOffset = int(offset / 1000)
        m.playbackTimer.Mark()
        m.player.Seek(offset)
    else if m.IsPaused then
        ' If we just call Seek while paused, we don't get a resumed event. This
        ' way the UI is always correct, but it's possible for a blip of audio.
        m.playbackOffset = int(offset / 1000)
        m.playbackTimer.Mark()
        m.player.Resume()
        m.player.Seek(offset)
    end if
End Sub

Sub audioPlayerNext()
    if m.Context = invalid then return

    maxIndex = m.Context.Count() - 1
    newIndex = m.CurIndex + 1

    if newIndex > maxIndex then newIndex = 0

    m.IgnoreTimelines = true
    m.Stop()
    m.CurIndex = newIndex
    m.player.SetNext(newIndex)
    m.Play()
End Sub

Sub audioPlayerPrev()
    if m.Context = invalid then return

    newIndex = m.CurIndex - 1
    if newIndex < 0 then newIndex = m.Context.Count() - 1

    m.IgnoreTimelines = true
    m.Stop()
    m.CurIndex = newIndex
    m.player.SetNext(newIndex)
    m.Play()
End Sub

Sub audioPlayerSetContext(context, contextIndex, screen, startPlayer)
    if startPlayer then
        m.IgnoreTimelines = true
        m.Stop()
    end if

    item = context[contextIndex]

    m.Context = context
    m.CurIndex = contextIndex

    if screen <> invalid then
        m.ContextScreenID = screen.ScreenID
    else
        m.ContextScreenID = invalid
    end if

    if item.server <> invalid then
        AddAccountHeaders(m.player, item.server.AccessToken)
    end if

    if screen = invalid then
        if RegRead("theme_music", "preferences", "loop") = "loop" then
            m.Repeat = 1
        else
            m.Repeat = 0
        end if
    else
        pref = RegRead("loopalbums", "preferences", "sometimes")
        if pref = "sometimes" then
            loop = (context.Count() > 1)
        else
            loop = (pref = "always")
        end if
        if loop then
            m.SetRepeat(2)
        else
            m.SetRepeat(0)
        end if
    end if

    m.player.SetLoop(m.Repeat = 2)
    m.player.SetContentList(context)

    m.IsShuffled = (screen <> invalid AND screen.IsShuffled)
    if m.IsShuffled then
        NowPlayingManager().timelines["music"].attrs["shuffle"] = "1"
    else
        NowPlayingManager().timelines["music"].attrs["shuffle"] = "0"
    end if

    NowPlayingManager().SetControllable("music", "skipPrevious", context.Count() > 1)
    NowPlayingManager().SetControllable("music", "skipNext", context.Count() > 1)

    if startPlayer then
        m.player.SetNext(contextIndex)
        m.IsPlaying = false
        m.IsPaused = false
    else
        maxIndex = context.Count() - 1
        newIndex = contextIndex + 1
        if newIndex > maxIndex then newIndex = 0
        m.player.SetNext(newIndex)
    end if
End Sub

Sub audioPlayerShowContextMenu()
    dialog = createBaseDialog()
    dialog.Title = "Now Playing"
    dialog.Text = firstOf(m.Context[m.CurIndex].Title, "")

    if m.IsPlaying then
        dialog.SetButton("pause", "Pause")
    else if m.IsPaused then
        dialog.SetButton("resume", "Play")
    else
        dialog.SetButton("play", "Play")
    end if
    dialog.SetButton("stop", "Stop")

    if m.Context.Count() > 1 then
        dialog.SetButton("next_track", "Next Track")
        dialog.SetButton("prev_track", "Previous Track")
    end if

    dialog.SetButton("show", "Go to Now Playing")
    dialog.SetButton("close", "Close")

    dialog.HandleButton = audioPlayerMenuHandleButton
    dialog.ParentScreen = m
    dialog.Show()
End Sub

Function audioPlayerMenuHandleButton(command, data) As Boolean
    ' We're evaluated in the context of the dialog, but we want to be in the
    ' context of the audio player.
    obj = m.ParentScreen

    if command = "play" then
        obj.Play()
    else if command = "pause" then
        obj.Pause()
    else if command = "resume" then
        obj.Resume()
    else if command = "stop" then
        obj.Stop()
    else if command = "next_track" then
        obj.Next()
    else if command = "prev_track" then
        obj.Prev()
    else if command = "show" then
        dummyItem = CreateObject("roAssociativeArray")
        dummyItem.ContentType = "audio"
        dummyItem.Key = "nowplaying"
        GetViewController().CreateScreenForItem(dummyItem, invalid, ["Now Playing"])
    else if command = "close" then
        return true
    end if

    ' For now, close the dialog after any button press instead of trying to
    ' refresh the buttons based on the new state.
    return true
End Function

Sub audioPlayerPlayThemeMusic(item)
    themeItem = CreateObject("roAssociativeArray")
    themeItem.Url = item.server.serverUrl + item.theme
    themeItem.Title = item.Title + " Theme"
    themeItem.HasDetails = true
    themeItem.Type = "track"
    themeItem.ContentType = "audio"
    themeItem.StreamFormat = "mp3"
    themeItem.server = item.server

    m.SetContext([themeItem], 0, invalid, true)
    m.Play()
End Sub

Function audioPlayerGetPlaybackProgress() As Integer
    return m.playbackOffset + m.playbackTimer.GetElapsedSeconds()
End Function

Sub audioPlayerOnTimerExpired(timer)
    if timer.Name = "timeline"
        m.UpdateNowPlaying()
    end if
End Sub

Sub audioPlayerUpdateNowPlaying()
    if m.IgnoreTimelines then return
    state = "stopped"
    item = invalid
    time = 0

    m.timelineTimer.Active = m.IsPlaying

    if m.IsPlaying then
        state = "playing"
        time = 1000 * m.GetPlaybackProgress()
        item = m.Context[m.CurIndex]
    else if m.IsPaused then
        state = "paused"
        time = 1000 * m.playbackOffset
        item = m.Context[m.CurIndex]
    else if m.Context <> invalid then
        item = m.Context[m.CurIndex]
    end if

    if m.ContextScreenID <> invalid then
        NowPlayingManager().UpdatePlaybackState("music", item, state, time)
    end if
End Sub

Sub audioPlayerSetRepeat(repeatVal)
    if m.Repeat = repeatVal then return

    m.Repeat = repeatVal
    m.player.SetLoop(repeatVal = 2)

    if repeatVal = 1 then
        m.player.SetNext(m.CurIndex)
    end if

    NowPlayingManager().timelines["music"].attrs["repeat"] = tostr(repeatVal)
End Sub

Sub audioPlayerSetShuffle(shuffleVal)
    newVal = (shuffleVal = 1)
    if newVal = m.IsShuffled then return

    m.IsShuffled = newVal
    if m.IsShuffled then
        m.CurIndex = ShuffleArray(m.Context, m.CurIndex)
    else
        m.CurIndex = UnshuffleArray(m.Context, m.CurIndex)
    end if

    m.player.SetContentList(m.Context)
    maxIndex = m.Context.Count() - 1
    newIndex = m.CurIndex + 1
    if newIndex > maxIndex then newIndex = 0
    m.player.SetNext(newIndex)

    NowPlayingManager().timelines["music"].attrs["shuffle"] = tostr(shuffleVal)
End Sub
