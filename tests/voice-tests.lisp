;;; voice-tests.lisp --- Voice Processing Tests
;;;
;;; This file contains tests for voice processing features (STT, TTS).

(defpackage #:lisp-claw-tests.voice
  (:nicknames #:lc-tests.voice)
  (:use #:cl
        #:prove
        #:lisp-claw.voice.stt
        #:lisp-claw.voice.tts))

(in-package #:lisp-claw-tests.voice)

(defsuite test-voice "Voice processing tests")

;;; ============================================================================
;;; STT Tests
;;; ============================================================================

(deftest test-transcription-creation "Transcription creation"
  (let ((transcription (make-transcription "Hello world"
                                           :language "en"
                                           :duration 5.0
                                           :confidence 0.95)))
    (ok transcription)
    (is (string= (transcription-text transcription) "Hello world"))
    (is (string= (transcription-language transcription) "en"))
    (is (= (transcription-duration transcription) 5.0))
    (is (= (transcription-confidence transcription) 0.95))))

(deftest test-stt-provider-creation "STT provider creation"
  (let ((provider (make-stt-provider :whisper :api-key "test-key" :model "whisper-1")))
    (ok provider)
    (is (eq (stt-provider-type provider) :whisper))
    (is (string= (stt-provider-api-key provider) "test-key"))
    (is (string= (stt-provider-model provider) "whisper-1"))))

(deftest test-whisper-provider "Whisper provider"
  (let ((provider (make-instance 'whisper-stt
                                 :type :whisper
                                 :api-key "test-key"
                                 :model "whisper-1")))
    (ok provider)
    (is (string= (whisper-endpoint provider)
                 "https://api.openai.com/v1/audio/transcriptions"))))

(deftest test-google-stt-provider "Google STT provider"
  (let ((provider (make-instance 'google-stt
                                 :type :google
                                 :api-key "test-key"
                                 :model "default")))
    (ok provider)
    (is (string= (google-stt-endpoint provider)
                 "https://speech.googleapis.com/v1/speech:recognize"))))

(deftest test-azure-stt-provider "Azure STT provider"
  (let ((provider (make-azure-stt-provider "test-key" :region "westus" :model "default")))
    (ok provider)
    (is (string= (azure-stt-region provider) "westus"))))

(deftest test-audio-duration "Audio duration calculation"
  ;; 16000 samples/sec, 1 channel, 16 bits/sample = 32000 bytes/sec
  ;; 1 second of audio = 32000 bytes
  (let ((audio-data (make-array 32000 :element-type '(unsigned-byte 8))))
    (is (= (get-audio-duration audio-data
                               :sample-rate 16000
                               :channels 1
                               :bits-per-sample 16)
           1.0)))

  ;; 2 seconds
  (let ((audio-data (make-array 64000 :element-type '(unsigned-byte 8))))
    (is (= (get-audio-duration audio-data
                               :sample-rate 16000
                               :channels 1
                               :bits-per-sample 16)
           2.0))))

(deftest test-voice-settings "Voice settings"
  (let ((settings (make-voice-settings :speed 1.5 :pitch 0.8 :volume 0.7)))
    (ok settings)
    (is (= (voice-settings-speed settings) 1.5))
    (is (= (voice-settings-pitch settings) 0.8))
    (is (= (voice-settings-volume settings) 0.7)))

  ;; Test clamping
  (let ((settings (make-voice-settings :speed 3.0 :pitch -1.0)))
    (is (= (voice-settings-speed settings) 2.0))  ;; Clamped to max
    (is (= (voice-settings-pitch settings) 0.5)))) ;; Clamped to min

;;; ============================================================================
;;; TTS Tests
;;; ============================================================================

(deftest test-speech-result-creation "Speech result creation"
  (let* ((audio #(0 1 2 3))
         (result (make-speech-result audio :format "wav" :duration 2.0 :size 4)))
    (ok result)
    (ok (speech-result-audio result))
    (is (string= (speech-result-format result) "wav"))
    (is (= (speech-result-duration result) 2.0))
    (is (= (speech-result-size result) 4))))

(deftest test-tts-provider-creation "TTS provider creation"
  (let ((provider (make-tts-provider :openai :api-key "test-key" :voice "alloy")))
    (ok provider)
    (is (eq (tts-provider-type provider) :openai))
    (is (string= (tts-provider-api-key provider) "test-key"))
    (is (string= (tts-provider-voice provider) "alloy"))))

(deftest test-openai-tts-provider "OpenAI TTS provider"
  (let ((provider (make-instance 'openai-tts
                                 :type :openai
                                 :api-key "test-key"
                                 :voice "alloy")))
    (ok provider)
    (is (string= (openai-tts-endpoint provider)
                 "https://api.openai.com/v1/audio/speech"))
    ;; Check available voices
    (let ((voices (openai-tts-voices provider)))
      (ok (>= (length voices) 6)))))

(deftest test-google-tts-provider "Google TTS provider"
  (let ((provider (make-instance 'google-tts
                                 :type :google
                                 :api-key "test-key"
                                 :voice "en-US-Standard-A")))
    (ok provider)
    (is (string= (google-tts-endpoint provider)
                 "https://texttospeech.googleapis.com/v1/text:synthesize"))))

(deftest test-azure-tts-provider "Azure TTS provider"
  (let ((provider (make-azure-tts-provider "test-key" :region "eastus" :voice "en-US-JennyNeural")))
    (ok provider)
    (is (string= (azure-tts-region provider) "eastus"))
    (is (string= (tts-provider-voice provider) "en-US-JennyNeural"))))

(deftest test-elevenlabs-tts-provider "ElevenLabs TTS provider"
  (let ((provider (make-instance 'elevenlabs-tts
                                 :type :elevenlabs
                                 :api-key "test-key"
                                 :voice "Rachel")))
    (ok provider)
    (is (string= (elevenlabs-tts-endpoint provider)
                 "https://api.elevenlabs.io/v1/text-to-speech"))))

(deftest test-voice-settings-clamping "Voice settings clamping"
  ;; Speed should be clamped to 0.5-2.0
  (let ((settings (make-voice-settings :speed 0.1))
    (is (= (voice-settings-speed settings) 0.5)))

  (let ((settings (make-voice-settings :speed 3.0))
    (is (= (voice-settings-speed settings) 2.0)))

  ;; Volume should be clamped to 0.0-1.0
  (let ((settings (make-voice-settings :volume -0.5))
    (is (= (voice-settings-volume settings) 0.0)))

  (let ((settings (make-voice-settings :volume 1.5))
    (is (= (voice-settings-volume settings) 1.0))))

;;; ============================================================================
;;; Run Voice Tests
;;; ============================================================================

(defun run-voice-tests ()
  "Run all voice processing tests.

  Returns:
    Test results"
  (prove:run #'test-voice))
