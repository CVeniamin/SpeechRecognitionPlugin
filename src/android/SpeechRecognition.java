package org.apache.cordova.speech;

import java.util.ArrayList;

import org.apache.cordova.PermissionHelper;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.PluginResult;

import android.content.pm.PackageManager;
import android.util.Log;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.speech.RecognitionListener;
import android.speech.RecognizerIntent;
import android.speech.SpeechRecognizer;
import android.Manifest;

/**
 * Style and such borrowed from the TTS and PhoneListener plugins
 */
public class SpeechRecognition extends CordovaPlugin {
    private static final String LOG_TAG = SpeechRecognition.class.getSimpleName();
    public static final String ACTION_INIT = "init";
    public static final String ACTION_SPEECH_RECOGNIZE_START = "start";
    public static final String ACTION_SPEECH_RECOGNIZE_STOP = "stop";
    public static final String ACTION_SPEECH_RECOGNIZE_ABORT = "abort";
    public static final String NOT_PRESENT_MESSAGE = "Speech recognition is not present or enabled";

    private CallbackContext speechRecognizerCallbackContext;
    private boolean recognizerPresent = false;
    private SpeechRecognizer recognizer;
    private boolean aborted = false;
    private boolean listening = false;
    private boolean interimResults = false;
    private int maxAlternatives = 1;
    private String lang;

    private static String [] permissions = { Manifest.permission.RECORD_AUDIO };
    private static int RECORD_AUDIO = 0;

    protected void getMicPermission()
    {
        PermissionHelper.requestPermission(this, RECORD_AUDIO, permissions[RECORD_AUDIO]);
    }

    private void promptForMic()
    {
        PackageManager pm = cordova.getActivity().getApplicationContext().getPackageManager();
        if (pm.hasSystemFeature(PackageManager.FEATURE_MICROPHONE)){
            if(PermissionHelper.hasPermission(this, permissions[RECORD_AUDIO])) {
                this.startRecognition();
            }
            else
            {
                getMicPermission();
            }
        } else {
            fireErrorEvent(2, "Device does not have a microphone hence impossible to capture audio.");
            fireEvent("end");
        }
    }

    public void onRequestPermissionResult(int requestCode, String[] permissions,
                                          int[] grantResults) throws JSONException
    {
        for(int r:grantResults)
        {
            if(r == PackageManager.PERMISSION_DENIED)
            {
                fireErrorEvent(4, "Permission denied for microphone access.");
                fireEvent("end");
                return;
            }
        }
        promptForMic();
    }

    @Override
    public boolean execute(String action, JSONArray args, CallbackContext callbackContext) {
        // Dispatcher
        if (ACTION_INIT.equals(action)) {
            // init
            if (DoInit()) {
                callbackContext.sendPluginResult(new PluginResult(PluginResult.Status.OK));
                
                Handler loopHandler = new Handler(Looper.getMainLooper());
                loopHandler.post(new Runnable() {

                    @Override
                    public void run() {
                        recognizer = SpeechRecognizer.createSpeechRecognizer(cordova.getActivity().getBaseContext());
                        recognizer.setRecognitionListener(new SpeechRecognitionListner());
                    }
                    
                });
            } else {
                callbackContext.sendPluginResult(new PluginResult(PluginResult.Status.ERROR, NOT_PRESENT_MESSAGE));
            }
        }
        else if (ACTION_SPEECH_RECOGNIZE_START.equals(action)) {
            // recognize speech
            if (!recognizerPresent) {
                callbackContext.sendPluginResult(new PluginResult(PluginResult.Status.ERROR, NOT_PRESENT_MESSAGE));
            }
            this.lang = args.optString(0, "en");
            this.interimResults = args.optBoolean(1, false);
            this.maxAlternatives = args.optInt(2, 1);
            this.speechRecognizerCallbackContext = callbackContext;
            this.promptForMic();
        }
        else if (ACTION_SPEECH_RECOGNIZE_STOP.equals(action)) {
            stop(false);
        }
        else if (ACTION_SPEECH_RECOGNIZE_ABORT.equals(action)) {
            stop(true);
        }
        else {
            // Invalid action
            String res = "Unknown action: " + action;
            return false;
        }
        return true;
    }

    private void startRecognition() {

        final Intent intent = new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH);
        intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL,RecognizerIntent.LANGUAGE_MODEL_FREE_FORM);
        intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE,lang);
        intent.putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS,interimResults);
        intent.putExtra(RecognizerIntent.EXTRA_MAX_RESULTS,maxAlternatives);

        Handler loopHandler = new Handler(Looper.getMainLooper());
        loopHandler.post(new Runnable() {

            @Override
            public void run() {
                recognizer.startListening(intent);
            }

        });

        PluginResult res = new PluginResult(PluginResult.Status.NO_RESULT);
        res.setKeepCallback(true);
        this.speechRecognizerCallbackContext.sendPluginResult(res);
    }
    
    private void stop(boolean abort) {
        this.aborted = abort;
        Handler loopHandler = new Handler(Looper.getMainLooper());
        loopHandler.post(new Runnable() {

            @Override
            public void run() {
                recognizer.stopListening();
            }
            
        });
    }

    /**
     * Initialize the speech recognizer by checking if one exists.
     */
    private boolean DoInit() {
        this.recognizerPresent = SpeechRecognizer.isRecognitionAvailable(this.cordova.getActivity().getBaseContext());
        return this.recognizerPresent;
    }

    private void fireRecognitionEvent(ArrayList<String> transcripts, float[] confidences, boolean isFinal) {
        JSONObject event = new JSONObject();
        JSONArray results = new JSONArray();
        JSONArray alternatives = new JSONArray();
        try {
            for(int i=0; i<transcripts.size(); i++) {
                JSONObject alternative = new JSONObject();
                alternative.put("transcript", transcripts.get(i));
                // The spec has the final (isFinal) attribute as part of the result and not per alternative.
                // For backwards compatibility, we leave it here and let the Javascript add it to the result list.
                alternative.put("final", isFinal);
                if (confidences != null) {
                    alternative.put("confidence", confidences[i]);
                } else {
                    alternative.put("confidence", 0);
                }
                alternatives.put(alternative);
            }
            results.put(alternatives);
            event.put("type", "result");
            event.put("resultIndex", 0);
            event.put("emma", null);
            event.put("interpretation", null);
            event.put("results", results);
        } catch (JSONException e) {
            // this will never happen
        }
        PluginResult pr = new PluginResult(PluginResult.Status.OK, event);
        pr.setKeepCallback(true);
        this.speechRecognizerCallbackContext.sendPluginResult(pr); 
    }

    private void fireEvent(String type) {
        JSONObject event = new JSONObject();
        try {
            event.put("type",type);
        } catch (JSONException e) {
            // this will never happen
        }
        PluginResult pr = new PluginResult(PluginResult.Status.OK, event);
        pr.setKeepCallback(true);
        this.speechRecognizerCallbackContext.sendPluginResult(pr); 
    }

    private void fireErrorEvent(int errorCode, String message) {
        JSONObject event = new JSONObject();
        try {
            event.put("type","error");
            event.put("error", errorCode);
            event.put("message", message);
        } catch (JSONException e) {
            // this will never happen
        }
        PluginResult pr = new PluginResult(PluginResult.Status.ERROR, event);
        pr.setKeepCallback(true);
        this.speechRecognizerCallbackContext.sendPluginResult(pr); 
    }

    class SpeechRecognitionListner implements RecognitionListener {

        @Override
        public void onBeginningOfSpeech() {
            Log.d(LOG_TAG, "begin speech");
            fireEvent("start");
            fireEvent("audiostart");
            fireEvent("soundstart");
            fireEvent("speechstart");
        }

        @Override
        public void onBufferReceived(byte[] buffer) {
            Log.d(LOG_TAG, "buffer received");
        }

        @Override
        public void onEndOfSpeech() {
            Log.d(LOG_TAG, "end speech");
            fireEvent("speechend");
            fireEvent("soundend");
            fireEvent("audioend");
            fireEvent("end");
        }

        @Override
        public void onError(int error) {
            Log.d(LOG_TAG, "error speech "+error);
            if (listening || error == 9) {
                fireErrorEvent(4, "Error " + error);
                fireEvent("end");
            }
            listening = false;
        }

        @Override
        public void onEvent(int eventType, Bundle params) {
            Log.d(LOG_TAG, "event speech");
        }

        @Override
        public void onPartialResults(Bundle partialResults) {
            Log.d(LOG_TAG, "partial results");
            String str = new String();
            Log.d(LOG_TAG, "onPartialResults " + partialResults);
            ArrayList<String> transcript = partialResults.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
            float[] confidence = partialResults.getFloatArray(SpeechRecognizer.CONFIDENCE_SCORES);
            if (transcript.size() > 0) {
                Log.d(LOG_TAG, "fire recognition event");
                fireRecognitionEvent(transcript, confidence, false);
            }
        }

        @Override
        public void onReadyForSpeech(Bundle params) {
            Log.d(LOG_TAG, "ready for speech");
            listening = true;
        }

        @Override
        public void onResults(Bundle results) {
            Log.d(LOG_TAG, "results");
            String str = new String();
            Log.d(LOG_TAG, "onResults " + results);
            ArrayList<String> transcript = results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
            float[] confidence = results.getFloatArray(SpeechRecognizer.CONFIDENCE_SCORES);
            if (transcript.size() > 0) {
                Log.d(LOG_TAG, "fire recognition event");
                fireRecognitionEvent(transcript, confidence, true);
            } else {
                Log.d(LOG_TAG, "fire no match event");
                fireEvent("nomatch");
            }
            listening = false;
        }

        @Override
        public void onRmsChanged(float rmsdB) {
            //Log.d(LOG_TAG, "rms changed");
        }
        
    }
}