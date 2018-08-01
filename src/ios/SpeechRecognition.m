//
//  Created by jcesarmobile on 30/11/14.
//
//

#import "SpeechRecognition.h"
#import "iSpeechSDK.h"
#import <Speech/Speech.h>

@implementation SpeechRecognition

- (void) init:(CDVInvokedUrlCommand*)command
{
    NSString * key = [self.commandDelegate.settings objectForKey:[@"speechRecognitionApiKey" lowercaseString]];
    if (!key) {
        // If the new prefixed preference is not available, fall back to the original
        // preference name for backwards compatibility.
        key = [self.commandDelegate.settings objectForKey:[@"apiKey" lowercaseString]];
        if (!key) {
            key = @"developerdemokeydeveloperdemokey";
        }
    }

    if([key caseInsensitiveCompare:@"disable"] == NSOrderedSame) {
        // If the API key is set to "disable", then don't allow use of the iSpeech service.
        self.iSpeechRecognition = Nil;
    } else {
        iSpeechSDK *sdk = [iSpeechSDK sharedSDK];
        sdk.APIKey = key;
        self.iSpeechRecognition = [[ISSpeechRecognition alloc] init];
    }

    NSString * output = [self.commandDelegate.settings objectForKey:[@"speechRecognitionAllowAudioOutput" lowercaseString]];
    if(output && [output caseInsensitiveCompare:@"true"] == NSOrderedSame) {
        // If the allow audio output preference is set, the need to change the session category.
        // This allows for speech recognition and speech synthesis to be used in the same app.
        self.sessionCategory = AVAudioSessionCategoryPlayAndRecord;
    } else {
        // Maintain the original functionality for backwards compatibility.
        self.sessionCategory = AVAudioSessionCategoryRecord;
    }

    self.audioSession = Nil;
    self.audioEngine = [[AVAudioEngine alloc] init];
}

- (void) start:(CDVInvokedUrlCommand*)command
{
    if (!NSClassFromString(@"SFSpeechRecognizer") && !self.iSpeechRecognition) {
        [self sendErrorWithMessage:@"No speech recognizer service available." andCode:4];
        return;
    }

    self.command = command;
    [self sendEvent:(NSString *)@"start"];
    [self recognize];
}

- (void) recognize
{
    NSString * lang = [self.command argumentAtIndex:0];
    if (lang && [lang isEqualToString:@"en"]) {
        lang = @"en-US";
    }

    if (NSClassFromString(@"SFSpeechRecognizer")) {

        if (![self permissionIsSet]) {
            [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status){
                dispatch_async(dispatch_get_main_queue(), ^{

                    if (status == SFSpeechRecognizerAuthorizationStatusAuthorized) {
                        [self recordAndRecognizeWithLang:lang];
                    } else {
                        [self sendErrorWithMessage:@"Permission not allowed" andCode:4];
                    }

                });
            }];
        } else {
            [self recordAndRecognizeWithLang:lang];
        }
    } else if(self.iSpeechRecognition) {
        [self.iSpeechRecognition setDelegate:self];
        [self.iSpeechRecognition setLocale:lang];
        [self.iSpeechRecognition setFreeformType:ISFreeFormTypeDictation];
        NSError *error;
        if(![self.iSpeechRecognition listenAndRecognizeWithTimeout:10 error:&error]) {
            NSLog(@"ERROR: %@", error);
        }
    }
}

- (void) recordAndRecognizeWithLang:(NSString *) lang
{
    NSMutableDictionary * event = [[NSMutableDictionary alloc]init];
    [event setValue:@"start" forKey:@"type"];
    self.pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:event];
    [self.pluginResult setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:self.pluginResult callbackId:self.command.callbackId];
    
    NSLocale *locale = [[NSLocale alloc] initWithLocaleIdentifier:lang];
    self.sfSpeechRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:locale];
    if (!self.sfSpeechRecognizer) {
        [self sendErrorWithMessage:@"The language is not supported" andCode:7];
    } else {

        // Cancel the previous task if it's running.
        if ( self.recognitionTask ) {
            [self.recognitionTask cancel];
            self.recognitionTask = nil;
        }

        [self initAudioSession];

        self.recognitionRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
        self.recognitionRequest.shouldReportPartialResults = [[self.command argumentAtIndex:1] boolValue];

        self.speechStartSent = FALSE;

        self.recognitionTask = [self.sfSpeechRecognizer recognitionTaskWithRequest:self.recognitionRequest resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {

            if (error) {
                NSLog(@"error");
                [self stopAndRelease];
                [self sendErrorWithMessage:error.localizedFailureReason andCode:error.code];
            }

            if(!self.speechStartSent) {
                [self sendEvent:(NSString *)@"speechstart"];
                self.speechStartSent = TRUE;
            }

            if (result) {
                NSMutableArray * alternatives = [[NSMutableArray alloc] init];
                int maxAlternatives = [[self.command argumentAtIndex:2] intValue];
                for ( SFTranscription *transcription in result.transcriptions ) {
                    if (alternatives.count < maxAlternatives) {
                        float confMed = 0;
                        for ( SFTranscriptionSegment *transcriptionSegment in transcription.segments ) {
                            //NSLog(@"transcriptionSegment.confidence %f", transcriptionSegment.confidence);
                            confMed +=transcriptionSegment.confidence;
                        }
                        NSMutableDictionary * resultDict = [[NSMutableDictionary alloc]init];
                        [resultDict setValue:transcription.formattedString forKey:@"transcript"];
                        [resultDict setValue:[NSNumber numberWithBool:result.isFinal] forKey:@"final"];
                        [resultDict setValue:[NSNumber numberWithFloat:confMed/transcription.segments.count]forKey:@"confidence"];
                        [alternatives addObject:resultDict];
                    }
                }
                [self sendResults:@[alternatives]];
                if ( result.isFinal ) {
                    if(self.speechStartSent) {
                        [self sendEvent:(NSString *)@"speechend"];
                        self.speechStartSent = FALSE;
                    }

                    [self stopAndRelease];
                }
            }
        }];

        //AVAudioFormat *recordingFormat = [self.audioEngine.inputNode outputFormatForBus:0];
        AVAudioFormat *recordingFormat = [self.audioEngine.inputNode inputFormatForBus:0];
        //AVAudioFormat *recordingFormat = [[AVAudioFormat alloc]initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:44100.0 channels:1 interleaved:0];
        [self.audioEngine.inputNode installTapOnBus:0 bufferSize:1024 format:recordingFormat block:^(AVAudioPCMBuffer * _Nonnull buffer, AVAudioTime * _Nonnull when) {
            [self.recognitionRequest appendAudioPCMBuffer:buffer];
        }],

        [self.audioEngine prepare];
        [self.audioEngine startAndReturnError:nil];

        [self sendEvent:(NSString *)@"audiostart"];
    }
}

- (void) initAudioSession
{
    if(!self.audioSession) {
        self.audioSession = [AVAudioSession sharedInstance];
        [self.audioSession setMode:AVAudioSessionModeMeasurement error:nil];
        [self.audioSession setCategory:self.sessionCategory withOptions: AVAudioSessionCategoryOptionDefaultToSpeaker error:nil];
        [self.audioSession setActive:YES withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    }
}

- (BOOL) permissionIsSet
{
    SFSpeechRecognizerAuthorizationStatus status = [SFSpeechRecognizer authorizationStatus];
    return status != SFSpeechRecognizerAuthorizationStatusNotDetermined;
}

- (void)recognition:(ISSpeechRecognition *)speechRecognition didGetRecognitionResult:(ISSpeechRecognitionResult *)result
{
    NSMutableDictionary * alternativeDict = [[NSMutableDictionary alloc]init];
    [alternativeDict setValue:result.text forKey:@"transcript"];
    // The spec has the final attribute as part of the result and not per alternative.
    // For backwards compatibility, we leave it here and let the Javascript add it to the result list.
    [alternativeDict setValue:[NSNumber numberWithBool:YES] forKey:@"final"];
    [alternativeDict setValue:[NSNumber numberWithFloat:result.confidence]forKey:@"confidence"];
    NSArray * alternatives = @[alternativeDict];
    NSArray * results = @[alternatives];
    [self sendResults:results];
}

-(void) recognition:(ISSpeechRecognition *)speechRecognition didFailWithError:(NSError *)error
{
    if (error.code == 28 || error.code == 23) {
        [self sendErrorWithMessage:[error localizedDescription] andCode:7];
    }
}

-(void) sendResults:(NSArray *) results
{
    NSMutableDictionary * event = [[NSMutableDictionary alloc]init];
    [event setValue:@"result" forKey:@"type"];
    [event setValue:nil forKey:@"emma"];
    [event setValue:nil forKey:@"interpretation"];
    [event setValue:[NSNumber numberWithInt:0] forKey:@"resultIndex"];
    [event setValue:results forKey:@"results"];

    self.pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:event];
    [self.pluginResult setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:self.pluginResult callbackId:self.command.callbackId];
}

-(void) sendErrorWithMessage:(NSString *)errorMessage andCode:(NSInteger) code
{
    NSMutableDictionary * event = [[NSMutableDictionary alloc]init];
    [event setValue:@"error" forKey:@"type"];
    [event setValue:[NSNumber numberWithInteger:code] forKey:@"error"];
    [event setValue:errorMessage forKey:@"message"];
    self.pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:event];
    [self.pluginResult setKeepCallbackAsBool:NO];
    [self.commandDelegate sendPluginResult:self.pluginResult callbackId:self.command.callbackId];
}

-(void) sendEvent:(NSString *) eventType
{
    NSMutableDictionary * event = [[NSMutableDictionary alloc]init];
    [event setValue:eventType forKey:@"type"];
    self.pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:event];
    [self.pluginResult setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:self.pluginResult callbackId:self.command.callbackId];
}

-(void) stop:(CDVInvokedUrlCommand*)command
{
    [self stopOrAbort];
}

-(void) abort:(CDVInvokedUrlCommand*)command
{
    [self stopOrAbort];
}

-(void) stopOrAbort
{
  if (NSClassFromString(@"SFSpeechRecognizer")) {
      if (self.audioEngine.isRunning) {
          [self.audioEngine stop];
          [self sendEvent:(NSString *)@"audioend"];

          [self.recognitionRequest endAudio];
      }
  } else if(self.iSpeechRecognition) {
      [self.iSpeechRecognition cancel];
  } else {
      [self sendErrorWithMessage:@"No speech recognizer service available." andCode:4];
  }
  @catch (NSException *exception) {
      [self sendErrorWithMessage:exception.reason andCode:124];
  }
}

-(void) stopAndRelease
{
    if (self.audioEngine.isRunning) {
        [self.audioEngine stop];
        [self sendEvent:(NSString *)@"audioend"];
    }
    [self.audioEngine.inputNode removeTapOnBus:0];

    [self.recognitionRequest endAudio];
    self.recognitionRequest = nil;

    if(self.recognitionTask.state != SFSpeechRecognitionTaskStateCompleted) {
        [self.recognitionTask cancel];
    }
    self.recognitionTask = nil;

    if(self.audioSession) {
        [self.audioSession setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    }

    [self sendEvent:(NSString *)@"end"];
}

@end
