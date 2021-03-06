//
//  SogamoAPI.m
//  Sogamo SDK
//
//  Created by Muhammad Mohsin on 11/9/12.
//  Copyright (c) 2012 White Dwarf Labs. All rights reserved.
//

#pragma mark Defines

#define AUTHENTICATION_SERVER_URL @"http://auth.sogamo.com"
#define FLUSH_URL_SUFFIX @"batch"
#define SESSIONS_DATA_FILE_NAME @"sogamo_sessions_data.bin"
#define API_DEFINITIONS_FILE_NAME @"sogamo_api_definitions.plist"

#define SESSIONS_DATA_EVENTS_KEY @"events"
#define SESSIONS_DATA_GAME_ID_KEY @"game_id"
#define SESSIONS_DATA_SESSIONS_KEY @"sessions"
#define SESSIONS_DATA_PLAYER_ID_KEY @"player_id"
#define SESSIONS_DATA_SESSION_ID_KEY @"session_id"
#define SESSIONS_DATA_LOG_COLLECTOR_URL_KEY @"lc_url"
#define SESSIONS_DATA_LATEST_SESSION_KEY @"latest_session"
#define SESSIONS_DATA_IS_OFFLINE_SESSION @"is_offline_session"
#define SESSIONS_DATA_SESSION_START_DATE_KEY @"session_start_date"
#define SESSIONS_DATA_LATEST_SESSION_START_DATE_KEY @"latest_session_start_date"

#define DEFINITIONS_DATA_REQUIRED_PARAMETERS_KEY @"required_parameters"
#define DEFINITIONS_DATA_API_DEFINITIONS_KEY @"api_definitions"
#define DEFINITIONS_DATA_PARAMETERS_KEY @"parameters"
#define DEFINITIONS_EVENT_INDEX_KEY @"event_index"
#define DEFINITIONS_DATA_REQUIRED_KEY @"required"
#define DEFINITIONS_DATA_VERSION_KEY @"version"
#define DEFINITIONS_DATA_TYPE_KEY @"type"

#define SESSION_TIME_OUT_PERIOD 43200
#define UUID_SALT @"com.sogamo.api"
#define MIN_FLUSH_INTERVAL 0
#define MAX_FLUSH_INTERVAL 3600

#import "SogamoAPI.h"

#import "SogamoAuthenticationResponse.h"
#import "SogamoSuggestionResponse.h"
#import "SogamoDeviceUtilities.h"
#import "SogamoJSONUtilities.h"
#import "SogamoReachability.h"
#import <dispatch/dispatch.h>
#import "SogamoSession.h"
#import "SogamoEvent.h"
#import "ARCMacros.h"

#pragma mark - Private Interface
@interface SogamoAPI() {
    NSString *_defaultPlayerId;
    UIBackgroundTaskIdentifier _bgTask;
    dispatch_queue_t _backgroundQueue;
}

@property (nonatomic, strong) NSString *apiKey;
@property (nonatomic, strong) SogamoSession *currentSession;
@property (nonatomic, strong) NSMutableArray *allSessions;
@property (nonatomic, strong) NSDictionary *playerDetails;
@property (nonatomic, strong) NSDictionary *apiDefinitionsData;
@property (nonatomic) float apiDefinitionsVersion;
@property (nonatomic, strong) NSTimer *flushTimer;

#pragma mark Authentication

- (SogamoAuthenticationResponse *) authenticateWithAPIKey:(NSString *)anAPIKey playerId:(NSString *)aPlayerId;

#pragma mark Track Events

- (void) privateTrackEventWithName:(NSString *)eventName params:(NSDictionary *)paramsDict forSession:(SogamoSession *)session;
- (SogamoEvent *) createEventWithName:(NSString *)eventName params:(NSDictionary *)paramsDict session:(SogamoSession *)session;

#pragma mark Sending Data

- (void) flush;

#pragma mark API Definitions

- (void) loadAPIDefinitionsData;
- (NSString *) getEventIndexForName:(NSString *)eventName;

#pragma mark Validation

- (BOOL) validateEvent:(SogamoEvent *)eventDict;

#pragma mark Session Renewal

- (SogamoSession *) createSessionWithAuthenticationResponse:(SogamoAuthenticationResponse *)authenticationResponse;
- (SogamoSession *) createOfflineSession;
- (void) getNewSessionIfNeeded;

#pragma mark Session Persistence

- (void) loadSessionsData;
- (void) saveSessions;
- (NSString *) sessionsDataFilePath;

#pragma mark Offline Sessions

- (NSString *) generateOfflineSessionKey;
- (BOOL) convertOfflineSessions;
- (void) convertOfflineSession:(SogamoSession *)offlineSession withResponse:(SogamoAuthenticationResponse *)response;
- (NSMutableArray *) convertOfflineEvents:(NSArray *)events withResponse:(SogamoAuthenticationResponse *)response;

#pragma mark Periodic Flush

- (void) startPeriodicFlush:(NSTimer *)timer;

#pragma mark Validation

- (BOOL) validateStartSession;

#pragma mark Convenience Methods

- (BOOL) hasSessionExpired:(SogamoSession *)session;
- (BOOL) hasCurrentSessionExpired;
- (BOOL) isCurrentSessionTemporary;

@end

#pragma mark -
@implementation SogamoAPI

#pragma mark - Public

static id sharedAPI = nil;

+ (void)initialize 
{
    if (self == [SogamoAPI class]) {
        sharedAPI = [[self alloc] init];
    }
}

- (id)init
{
    self = [super init];
    if (self) {
        _defaultPlayerId = SAFE_ARC_RETAIN([SogamoDeviceUtilities generateUUIDWithSalt:UUID_SALT]);
        // Create background queue for use with GCD
        _backgroundQueue = dispatch_queue_create("com.sogamo.api.bgqueue", NULL);

        _playerDetails = [[NSDictionary alloc] init];
        _flushInterval = 0;
        _currentSession = SAFE_ARC_RETAIN([self createOfflineSession]);
        
        // Register for notifications
        [[NSNotificationCenter defaultCenter] addObserver:self 
                                                 selector:@selector(handleApplicationDidEnterBackgroundNotification:) 
                                                     name:UIApplicationDidEnterBackgroundNotification 
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleApplicationWillEnterForegroundNotification:) 
                                                     name:UIApplicationWillEnterForegroundNotification 
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleApplicationWillTerminate::) 
                                                     name:UIApplicationWillTerminateNotification 
                                                   object:nil];  
        
        [self loadSessionsData];
        [self loadAPIDefinitionsData];        
    }
    return self;
}

+ (id)sharedAPI 
{
    return sharedAPI;
}

#pragma mark Property accessors

//- (NSString *) playerId
//{
//    // If no playerId has been set by the user, then return the default playerId instead
//    if (_playerId) {
//        return _playerId;
//    } else {
//        return _defaultPlayerId;
//    }
//}

- (void) setFlushInterval:(NSInteger)flushInterval
{
    // Clamp the flush interval between the MIN and MAX values
    if (flushInterval < MIN_FLUSH_INTERVAL) {
        flushInterval = MIN_FLUSH_INTERVAL;
    } else if (flushInterval > MAX_FLUSH_INTERVAL) {
        flushInterval = MAX_FLUSH_INTERVAL;
    }

    // Only update if new value is different
    if (flushInterval != _flushInterval) {
        _flushInterval = flushInterval;
        
        if (_flushInterval > 0) {
            // Cancel any pre-existing timers
            [self.flushTimer invalidate];
            
            NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:(NSTimeInterval)_flushInterval
                                                              target:self
                                                            selector:@selector(startPeriodicFlush:)
                                                            userInfo:nil
                                                             repeats:YES];
            self.flushTimer = timer;
        }
    }
}

#pragma mark Startup

- (void) startSessionWithAPIKey:(NSString *)anAPIKey
{
    [self startSessionWithAPIKey:anAPIKey playerId:_defaultPlayerId playerDetails:[NSDictionary dictionary]];
}

- (void) startSessionWithAPIKey:(NSString *)anAPIKey playerId:(NSString *)aPlayerId playerDetails:(NSDictionary *)aPlayerDetails
{
    dispatch_async(_backgroundQueue, ^(void) {
        self.apiKey = anAPIKey;
        self.playerId = aPlayerId;
        self.playerDetails = aPlayerDetails;
        if ([self validateStartSession]) {
            [self getNewSessionIfNeeded];
            [self convertOfflineSessions];
        }
    });    
}

#pragma mark Event Tracking

- (void) trackEventWithName:(NSString *)eventName params:(NSDictionary *)paramsDict
{           
    dispatch_async(_backgroundQueue, ^(void) {
        [self privateTrackEventWithName:eventName params:paramsDict forSession:self.currentSession];
    });
}

#pragma mark Request Suggestions

- (void) requestSuggestionOfType:(NSString *)suggestionType
                         success:(SogamoSuggestionSuccess)successBlock
                           error:(SogamoSuggestionError)errorBlock
{
    if (!self.currentSession || !self.apiKey || !self.playerId) {
        NSLog(@"Unable to request suggestion. Call startSessionWithAPIKey:playerId:playerDetails: first!");
        return;
    }
    
    if (!self.currentSession.suggestionServerURL) {
        NSLog(@"Unable to request suggestion. Suggestion Server URL is missing!");
        return;
    }
    
    dispatch_async(_backgroundQueue, ^(void) {
        if ([SogamoReachability isURLReachable:self.currentSession.suggestionServerURL]) {
            NSString *completeSuggestionURLString =
            [NSString stringWithFormat:@"%@?apiKey=%@&playerId=%@&suggestionType=%@",
             self.currentSession.suggestionServerURL.absoluteString,
             self.apiKey,
             self.playerId,
             suggestionType];

            NSURL *completeSuggestionURL = [NSURL URLWithString:completeSuggestionURLString];
            NSURLRequest *suggestionURLRequest = [NSURLRequest requestWithURL:completeSuggestionURL];
            
            NSError *error;
            NSHTTPURLResponse *response;
            NSData *responseData = [NSURLConnection sendSynchronousRequest:suggestionURLRequest
                                                         returningResponse:&response
                                                                     error:&error];
            
            if (responseData) {
                // Successful request
                NSError *decodingError = nil;
                
                id decodedData = SogamoJSONDecode(responseData, &decodingError);
                if (decodingError) {
                    NSLog(@"Decoding error (%i %@): %@", response.statusCode, [NSHTTPURLResponse localizedStringForStatusCode:response.statusCode], [decodingError localizedDescription]);
                    errorBlock(decodingError);
                } else {
                    NSDictionary *jsonResponseDictionary = (NSDictionary *)decodedData;
                    if (jsonResponseDictionary[@"error"]) {
                        NSDictionary *userInfo = @{NSLocalizedDescriptionKey : jsonResponseDictionary[@"error"]};
                        error = [NSError errorWithDomain:@"Sogamo Server Error" code:100 userInfo:userInfo];
                        errorBlock(error);
                    } else {
                        SogamoSuggestionResponse *suggestionResponse = [[SogamoSuggestionResponse alloc] initWithDictionary:jsonResponseDictionary];
                        if (suggestionResponse) {
                            successBlock(suggestionResponse.suggestion);
                        }
                    }
                }
            } else {
                // Failed request
                errorBlock(error);
            }
        } else {
            NSLog(@"Suggestion Server is unreachable right now. Try again later.");
            return;
        }
    });
}


#pragma mark - Private

#pragma mark Authentication

- (SogamoAuthenticationResponse *) authenticateWithAPIKey:(NSString *)anAPIKey playerId:(NSString *)aPlayerId
{
    SogamoAuthenticationResponse *authenticationResponse = nil;
    
    if ([SogamoReachability isURLStringReachable:AUTHENTICATION_SERVER_URL]) {
        NSString *urlString = AUTHENTICATION_SERVER_URL;
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@?apiKey=%@&playerId=%@", urlString, anAPIKey, aPlayerId]];
        
        NSURLRequest *urlRequest = [NSURLRequest requestWithURL:url];
            
        NSError *error;
        NSHTTPURLResponse *response;
        NSData *responseData = [NSURLConnection sendSynchronousRequest:urlRequest 
                                                     returningResponse:&response 
                                                                 error:&error];
        
        if (responseData) {
            // Successful request
            NSError *decodingError = nil;
            
            id decodedData = SogamoJSONDecode(responseData, &decodingError);
            if (decodingError) {
                NSLog(@"Decoding error (%i %@): %@", response.statusCode, [NSHTTPURLResponse localizedStringForStatusCode:response.statusCode], [decodingError localizedDescription]);
                [[NSNotificationCenter defaultCenter] postNotificationName:SogamoAPIDidFailToAuthenticateNotification object:decodingError];
            } else {
                authenticationResponse = [[SogamoAuthenticationResponse alloc] initWithDictionary:(NSDictionary *)decodedData];
                [[NSNotificationCenter defaultCenter] postNotificationName:SogamoAPIDidSuccessfullyAuthenticateNotification
                                                                    object:nil];
            }
        } else {
            // Failed request
            NSLog(@"Request Error (%i %@): %@", response.statusCode, [NSHTTPURLResponse localizedStringForStatusCode:response.statusCode], error.description);
            [[NSNotificationCenter defaultCenter] postNotificationName:SogamoAPIDidFailToAuthenticateNotification object:error];
        }     
    } else {
        NSLog(@"Server not reachable. Authentication request failed");
    }
    
    return authenticationResponse;
}

#pragma mark Track Events

- (void) privateTrackEventWithName:(NSString *)eventName params:(NSDictionary *)paramsDict forSession:(SogamoSession *)session
{
    SogamoEvent *newEvent = [self createEventWithName:eventName params:paramsDict session:session];
    if (newEvent) {
        [session.events addObject:newEvent];
        NSLog(@"'%@' event successfully tracked!", eventName);
    }
}

- (SogamoEvent *) createEventWithName:(NSString *)eventName params:(NSDictionary *)paramsDict session:(SogamoSession *)session
{
    if (!session) {
        NSLog(@"A Sogamo session must be created with startSessionWithAPIKey: before any events can be tracked!");
        return nil;
    }
    
    if (!eventName) {
        NSLog(@"Event Name cannot be nil!");
        return nil;
    }
    
    if (!paramsDict) {
        NSLog(@"Event Params cannot be nil!");
        return nil;
    }
    
    NSString *eventIndex = [self getEventIndexForName:eventName];
    
    // Insert session-wide parameters (if necessary by checking required params list)
    NSMutableDictionary *mutableDataDict = [NSMutableDictionary dictionaryWithDictionary:paramsDict];
    NSArray *requiredParams = [[self.apiDefinitionsData objectForKey:eventName] objectForKey:@"required_parameters"];
    for (NSString *requiredParam in requiredParams) {
        if ([requiredParam isEqualToString:@"session_id"] || [requiredParam isEqualToString:@"sessionId"]) {
            [mutableDataDict setObject:session.sessionId forKey:requiredParam];
        }
        if ([requiredParam isEqualToString:@"game_id"] || [requiredParam isEqualToString:@"gameId"]) {
            [mutableDataDict setObject:[NSNumber numberWithInt:session.gameId] forKey:requiredParam];
        }
        if ([requiredParam isEqualToString:@"player_id"] || [requiredParam isEqualToString:@"playerId"]) {
            [mutableDataDict setObject:session.playerId forKey:requiredParam];
        }
        if ([requiredParam isEqualToString:@"login_datetime"]) {
            [mutableDataDict setObject:session.startDate forKey:requiredParam];
        }
        if ([requiredParam isEqualToString:@"logDatetime"]) {
            [mutableDataDict setObject:[NSDate date] forKey:requiredParam];
        }
        if ([requiredParam isEqualToString:@"updatedDatetime"]) {
            [mutableDataDict setObject:[NSDate date] forKey:requiredParam];
        }
        if ([requiredParam isEqualToString:@"last_active_datetime"]) {
            [mutableDataDict setObject:[NSDate date] forKey:requiredParam];
        }
    }
    
    SogamoEvent *event = SAFE_ARC_AUTORELEASE([[SogamoEvent alloc] initWithName:eventName index:eventIndex params:mutableDataDict]);
    
    if ([self validateEvent:event]) {
        return event;
    } else {
        return nil;
    }    
}

#pragma mark Flush / Send Event Data

- (void) flush
{
    if (!self.allSessions || [self.allSessions count] == 0) {
        NSLog(@"No data to send!");
        return;
    }
    
//    NSURL *flushURL = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@", self.currentSession.logCollectorURL]];
    NSURL *flushURL = self.currentSession.logCollectorURL;
    if (flushURL) {
        flushURL = [flushURL URLByAppendingPathComponent:FLUSH_URL_SUFFIX];
    } else {
        NSLog(@"Log Collector URL is malformed! (%@)", self.currentSession.logCollectorURL);
        return;
    }
    
    if ([SogamoReachability isURLReachable:flushURL]) {
        NSLog(@"Flushing sessions data...");
        NSLog(@"Sessions to flush: %@", self.allSessions);

        NSMutableArray *sessionsToRemove = [NSMutableArray array];
        // Convert each sessions' event into an array of JSON Strings
        for (SogamoSession *session in self.allSessions) {
            NSArray *jsonEvents = [session convertEventsToJSON];
            
            // If jsonEvents is empty, mark it for removal and skip this loop iteration
            if ([jsonEvents count] == 0) {
                [sessionsToRemove addObject:session];
                continue;
            }
            
            NSMutableString *postBody = [[NSMutableString alloc] init];
            
            // Add each event as a param to the url string
            for (int i=0; i<[jsonEvents count]; i++) {
                NSString *encodedJSONEvent = [NSString stringWithFormat:@"%i=%@&", i, [jsonEvents[i] stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
                [postBody appendString:encodedJSONEvent];
//                NSLog(@"%@", jsonEvents[i]);
            }
            
            // Delete trailing & symbol
            [postBody deleteCharactersInRange:NSMakeRange([postBody length]-1, 1)];
//            NSLog(@"%@", postBody);
            
            // Attempt to send aggregated session data
            NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:flushURL];
            [urlRequest setHTTPMethod:@"POST"];
            [urlRequest setHTTPBody:[postBody dataUsingEncoding:NSUTF8StringEncoding]];
            
            NSError *connectionError = nil;
            NSHTTPURLResponse *response = nil;
            NSData *responseData = [NSURLConnection sendSynchronousRequest:urlRequest
                                                         returningResponse:&response
                                                                     error:&connectionError];
            
            if (connectionError) {
                // Failed request
                NSLog(@"Request Error (%i %@): %@", response.statusCode, [NSHTTPURLResponse localizedStringForStatusCode:response.statusCode], connectionError.description);
                break;
            } else {
                if (response.statusCode == 200) {
                    NSLog(@"Session %@ successfully sent!", session.sessionId);
                    [sessionsToRemove addObject:session];
                } else {
                    NSString *responseString = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
                    NSLog(@"Server Error: %@", responseString);
                }
            }            
        }
        
        // After successful delivery, delete from the persisted sessions data
        if ([sessionsToRemove count] > 0)
            [self.allSessions removeObjectsInArray:sessionsToRemove];
        
        // Re-insert the current session into the allSessions array if removed
        if ([self.allSessions count] == 0) {
            // Clear the existing events array in the current session since it has already been flushed
            [self.currentSession.events removeAllObjects];
            [self.allSessions addObject:self.currentSession];
        }
    } else {
        NSLog(@"Log Collector (%@) not reachable. Flush attempt failed.", flushURL.host);
    }
}

#pragma mark API Definitions

- (void) loadAPIDefinitionsData
{
    NSString *apiDefinitionsFileName = API_DEFINITIONS_FILE_NAME;
    NSArray *apiDefinitionsFileNameParts = [apiDefinitionsFileName componentsSeparatedByString:@"."];
    NSString *apiDefinitionsFilePath = [[NSBundle mainBundle] pathForResource:[apiDefinitionsFileNameParts objectAtIndex:0] 
                                                                       ofType:[apiDefinitionsFileNameParts objectAtIndex:1]];
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:apiDefinitionsFilePath]) {   
        NSMutableDictionary *apiDefinitionsFileDict = [NSMutableDictionary dictionaryWithContentsOfFile:apiDefinitionsFilePath];
        NSMutableDictionary *apiDefinitions = [apiDefinitionsFileDict objectForKey:DEFINITIONS_DATA_API_DEFINITIONS_KEY];
        
        // Iterate through each declared API
        for (NSString *apiDefinitionKey in [apiDefinitions allKeys]) {
            NSMutableDictionary *apiDefinitionDict = [apiDefinitions objectForKey:apiDefinitionKey];            
            
            // Create an array of required params and insert into the definitions dict
            NSDictionary *params = [apiDefinitionDict objectForKey:DEFINITIONS_DATA_PARAMETERS_KEY];            
            NSMutableArray *requiredParams = [NSMutableArray array];
            for (NSString *paramsKey in [params allKeys]) {
                NSDictionary *paramsDict = [params objectForKey:paramsKey];
                BOOL isRequired = [[paramsDict objectForKey:DEFINITIONS_DATA_REQUIRED_KEY] boolValue];
                if (isRequired) {
                    [requiredParams addObject:paramsKey];
                }
            }
            [apiDefinitionDict setObject:requiredParams forKey:DEFINITIONS_DATA_REQUIRED_PARAMETERS_KEY];
        }
        
        self.apiDefinitionsData = [NSDictionary dictionaryWithDictionary:apiDefinitions];
        self.apiDefinitionsVersion = [[apiDefinitionsFileDict objectForKey:DEFINITIONS_DATA_VERSION_KEY] floatValue];
    } else {
        NSLog(@"API Definitions File is missing!");
    }
}

- (NSString *) getEventIndexForName:(NSString *)eventName
{
    if (!self.apiDefinitionsData) {
        NSLog(@"API Definitions data is missing!");
        return nil;
    }
    
    NSString *eventIndex = nil;
    if ([self.apiDefinitionsData objectForKey:eventName]) {
        NSDictionary *eventDict = [self.apiDefinitionsData objectForKey:eventName];
        eventIndex = [eventDict objectForKey:DEFINITIONS_EVENT_INDEX_KEY];
    } else {
        NSLog(@"No such event Name!");
    }
    
    return eventIndex;
}

#pragma mark Validation

- (BOOL) validateEvent:(SogamoEvent *)event
{
    if (!self.apiDefinitionsData) {
        NSLog(@"API Definitions data is missing!");
        return NO;
    }
    
    BOOL result = YES;
    
    NSString *eventName = event.eventName;
    NSString *eventIndex = event.eventIndex;
    NSDictionary *eventDataDict = event.eventParams;
    
    // Check if the given event index matches the given event name
    if ([[self getEventIndexForName:eventName] isEqualToString:eventIndex]) {
        NSDictionary *definitionDict = [self.apiDefinitionsData objectForKey:eventName];
        NSDictionary *definitionParamatersDict = [definitionDict objectForKey:DEFINITIONS_DATA_PARAMETERS_KEY];
        
        // Check each given parameter
        for (NSString *parameterKey in [eventDataDict allKeys]) {
            // Check whether the parameter exists in the definitions file
            if ([definitionParamatersDict objectForKey:parameterKey]) {
                NSDictionary *parameterDict = [definitionParamatersDict objectForKey:parameterKey];
                
                // Check whether parameter value is of the correct type
                id parameterValue = [eventDataDict objectForKey:parameterKey];
                
                NSString *parameterType = [parameterDict objectForKey:DEFINITIONS_DATA_TYPE_KEY];
                Class expectedParameterValueClass = NULL;
                if ([parameterType isEqualToString:@"BOOL"]) {
                    expectedParameterValueClass = [NSNumber class];
                } else {
                    expectedParameterValueClass = NSClassFromString(parameterType);
                }
                
                if (![parameterValue isKindOfClass:expectedParameterValueClass]) {
                    NSLog(@"Value for parameter %@ is not the correct type!", parameterKey);
                    result = NO;
                    break;
                }
            } else {
                NSLog(@"%@ is not a valid parameter!", parameterKey);
                result = NO;
                break;
            }
        }
        
        // Check if all required parameters are present
        NSArray *requiredParameters = [definitionDict objectForKey:DEFINITIONS_DATA_REQUIRED_PARAMETERS_KEY];
        for (NSString *requiredParameter in requiredParameters) {
            if (![eventDataDict objectForKey:requiredParameter]) {
                NSLog(@"Required Parameter: \"%@\" is missing!", requiredParameter);
                result = NO;
                break;
            }
        }
        
    } else {
        NSLog(@"Event Index is incorrect for given event name!");
        result = NO;        
    }    
    
    return result;
}

#pragma mark Session Creation / Renewal

- (SogamoSession *) createSessionWithAuthenticationResponse:(SogamoAuthenticationResponse *)authenticationResponse
{
    if (!authenticationResponse) {
        NSLog(@"Invalid authentication response! Creating offline response instead");
        return [self createOfflineSession];
    }
    
    SogamoSession *newSession = SAFE_ARC_AUTORELEASE([[SogamoSession alloc] initWithSessionId:authenticationResponse.sessionId
                                                                                     playerId:authenticationResponse.playerId
                                                                                       gameId:authenticationResponse.gameId
                                                                              logCollectorURL:authenticationResponse.logCollectorURL
                                                                          suggestionServerURL:authenticationResponse.suggestionServerURL
                                                                             isOfflineSession:NO]);
    
    return newSession;
}

- (SogamoSession *) createOfflineSession
{
    NSLog(@"Generating Offline Session");
    SogamoSession *newSession = SAFE_ARC_AUTORELEASE([[SogamoSession alloc] initWithSessionId:[self generateOfflineSessionKey]
                                                                                     playerId:self.playerId
                                                                                       gameId:-1
                                                                              logCollectorURL:nil
                                                                          suggestionServerURL:nil
                                                                             isOfflineSession:YES]);
    
    return newSession;
}

- (void) getNewSessionIfNeeded
{
    // Check if there an existing current session
    if (self.currentSession) {
        // Check if current session is temporary
        if ([self isCurrentSessionTemporary]) {
            SogamoAuthenticationResponse *authenticationResponse = [self authenticateWithAPIKey:self.apiKey playerId:self.playerId];
            if (authenticationResponse) {
                [self convertOfflineSession:self.currentSession withResponse:authenticationResponse];
            }
            
            [self privateTrackEventWithName:@"session" params:self.playerDetails forSession:self.currentSession];
            NSLog(@"Converting temporary session. Session ID: %@", self.currentSession.sessionId);
        } else {
//            NSLog(@"Current session is still valid. No new session key required");
            [self privateTrackEventWithName:@"session" params:[NSDictionary dictionary] forSession:self.currentSession];
        }
    } else {
        NSLog(@"No session detected. Creating a new one...");
        SogamoAuthenticationResponse *authenticationResponse = [self authenticateWithAPIKey:self.apiKey playerId:self.playerId];
        if (authenticationResponse) {
            self.currentSession = [self createSessionWithAuthenticationResponse:authenticationResponse];
        } else {
            self.currentSession = [self createOfflineSession];
        }
        
        [self privateTrackEventWithName:@"session" params:self.playerDetails forSession:self.currentSession];
        NSLog(@"New session created! Session ID: %@", self.currentSession.sessionId);
    }
    
    if (![self.allSessions containsObject:self.currentSession]) {
        [self.allSessions addObject:self.currentSession];
    }
}

#pragma mark Session Persistence

- (void) loadSessionsData
{
    NSString *sessionsDataFilePath = [self sessionsDataFilePath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:sessionsDataFilePath]) {
        self.allSessions = [NSKeyedUnarchiver unarchiveObjectWithFile:sessionsDataFilePath];
        
        if (!self.allSessions || [self.allSessions count] == 0) {
            NSLog (@"Persisted Sessions Data is nil!");
        }
        
        //Restore the most recent session (will be the last one in the array)
        if ([self.allSessions count] > 0) {
            // Check if the most recent session has expired
            SogamoSession *mostRecentSession = [self.allSessions objectAtIndex:[self.allSessions count] - 1];
            if ([self hasSessionExpired:mostRecentSession]) {
                NSLog(@"Current session has expired. Using Temporary session instead");
            } else {
                NSLog(@"Current session is still valid. No new session key required");
                self.currentSession = mostRecentSession;
            }
        }
//        NSLog(@"All Sessions: %@", self.allSessions);
    } else {
        NSLog(@"No Sessions Data file found!");
        self.allSessions = [NSMutableArray array];
    }            
}

- (void) saveSessions
{    
    if (self.allSessions == nil || [self.allSessions count] == 0) {
        NSLog(@"No Sessions data to persist!");
        return;
    }
    
//    NSLog(@"%@", [self sessionsDataFilePath]);
    BOOL successfulSave = [NSKeyedArchiver archiveRootObject:self.allSessions toFile:[self sessionsDataFilePath]];
    if (successfulSave) {
        NSLog(@"Sucessfully saved sessions data to file!");
    } else {
        NSLog(@"Failed to save sesssion data to file!");
    }
}

- (NSString *) sessionsDataFilePath
{
    NSString *documentsDirectory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    return [documentsDirectory stringByAppendingPathComponent:SESSIONS_DATA_FILE_NAME];
}

#pragma mark Offline Sessions

- (NSString *) generateOfflineSessionKey
{
    NSString *offlineSessionKey = nil;
    
    CFUUIDRef theUUID = CFUUIDCreate(NULL);
    offlineSessionKey = ( NSString *)CFUUIDCreateString(NULL, theUUID);
    CFRelease(theUUID);
  
    return SAFE_ARC_AUTORELEASE(offlineSessionKey);
}

- (BOOL) convertOfflineSessions
{
    if (!self.allSessions && [self.allSessions count] == 0) {
        return NO;
    }
    
    BOOL result = YES;
    
    for (SogamoSession *session in self.allSessions) {
        if (session.isOfflineSession) {
            // Request a new session key for the offline session
            SogamoAuthenticationResponse *authenticationResponse = [self authenticateWithAPIKey:self.apiKey playerId:self.playerId];
            if (authenticationResponse) {                
                [self convertOfflineSession:session withResponse:authenticationResponse];
            } else {
                NSLog(@"Attempt to convert an offline session failed.");
                result = NO;
                break;
            }
        }
    }
    
    return result;
}

- (void) convertOfflineSession:(SogamoSession *)offlineSession withResponse:(SogamoAuthenticationResponse *)response
{
    if (!offlineSession) {
        NSLog(@"Offline session is nil!");
        return;
    }
    
    if (!response) {
        NSLog(@"Authentication Response is nil!");
        return;
    }

    offlineSession.sessionId = response.sessionId;
    offlineSession.playerId = response.playerId;
    offlineSession.gameId = response.gameId;
    offlineSession.logCollectorURL = response.logCollectorURL;
    offlineSession.suggestionServerURL = response.suggestionServerURL;
    offlineSession.isOfflineSession = NO;
    
    // Convert all existing events
    NSMutableArray *convertedEvents = [self convertOfflineEvents:offlineSession.events withResponse:response];
    if (convertedEvents) {
        offlineSession.events = convertedEvents;
    }
    
    NSLog(@"Successfully converted an offline session");
}

- (NSMutableArray *) convertOfflineEvents:(NSArray *)events withResponse:(SogamoAuthenticationResponse *)response
{
    if (!events) {
        NSLog(@"Events is nil!");
        return nil;
    }
    
    if (!response) {
        NSLog(@"Authentication Response is nil");
        return nil;
    }
    
    NSMutableArray *convertedEvents = [NSMutableArray array];
    
    for (SogamoEvent *event in events) {
        if (event.eventParams[@"session_id"]) {
            event.eventParams[@"session_id"] = response.sessionId;
        } else if (event.eventParams[@"sessionId"]) {
            event.eventParams[@"sessionId"] = response.sessionId;
        }
        
        if (event.eventParams[@"player_id"]) {
            event.eventParams[@"player_id"] = response.sessionId;
        } else if (event.eventParams[@"playerId"]) {
            event.eventParams[@"playerId"] = response.sessionId;
        }

        if (event.eventParams[@"game_id"]) {
            event.eventParams[@"game_id"] = response.sessionId;
        } else if (event.eventParams[@"gameId"]) {
            event.eventParams[@"gameId"] = response.sessionId;
        }

        [convertedEvents addObject:event];
    }

    return convertedEvents;
}

#pragma mark Periodic Flush

- (void) startPeriodicFlush:(NSTimer *)timer
{
    dispatch_async(_backgroundQueue, ^(void) {
        // Check if a current session has been created
        if (self.currentSession) {
            // If existing offline sessions can be converted, proceed to flush
            if ([self convertOfflineSessions]) {
                [self flush];
                [self saveSessions];
            }
        }
    });
}

#pragma mark Validation

- (BOOL) validateStartSession
{
    BOOL result = YES;
    
    if (!self.apiKey || [self.apiKey isEqualToString:@""]) {
        NSLog(@"API Key is nil or empty!");
        result = NO;
    }
    
    if (!self.playerId || [self.playerId isEqualToString:@""]) {
        NSLog(@"Player ID is nil or empty!");
        result = NO;
    }
    
    if (!self.playerDetails) {
        NSLog(@"API Key is nil!");
        result = NO;
    }
    
    return result;
}

#pragma mark Convenience Methods

- (BOOL) hasSessionExpired:(SogamoSession *)session
{
    if (!session) {
        NSLog(@"Session is nil!");
        return YES;
    }
    
    if (!session.startDate) {
        NSLog(@"Session has no start date!");
        return YES;
    }
    
    NSTimeInterval currentSessionDuration = [[NSDate date] timeIntervalSinceDate:session.startDate];
    
    return currentSessionDuration >= SESSION_TIME_OUT_PERIOD;
}

- (BOOL) hasCurrentSessionExpired
{
    if (!self.currentSession.startDate) {
        NSLog(@"There is no current session");
        return YES;
    }
    
    NSTimeInterval currentSessionDuration = [[NSDate date] timeIntervalSinceDate:self.currentSession.startDate];
    
    return currentSessionDuration >= SESSION_TIME_OUT_PERIOD;
}

- (BOOL) isCurrentSessionTemporary
{
    if (!self.currentSession) {
        NSLog(@"Current session is nil!");
        return NO;
    }
    
    return (self.currentSession.isOfflineSession && self.currentSession.playerId == nil);
}

#pragma mark Notification Handling

- (void) handleApplicationDidEnterBackgroundNotification:(NSNotification *)notificiation
{
    UIApplication *app = [UIApplication sharedApplication];
    
    // Start Background Task
    _bgTask = [app beginBackgroundTaskWithExpirationHandler:^{
        NSLog(@"Background Task Timer expired");
        [app endBackgroundTask:_bgTask];
        _bgTask = UIBackgroundTaskInvalid;
    }];

    dispatch_async(_backgroundQueue, ^(void) {        
        // If existing offline sessions can be converted, proceed to flush
        if ([self convertOfflineSessions]) {
            [self flush];                    
        }
        
        [self saveSessions];
        
        // End Background Task (started in handleApplicationDidEnterBackgroundNotification:) if it hasn't expired already
        if (_bgTask != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:_bgTask];
            _bgTask = UIBackgroundTaskInvalid;        
        }                    
    });
}

- (void) handleApplicationWillEnterForegroundNotification:(NSNotification *)notification
{
    dispatch_async(_backgroundQueue, ^(void) {
        [self loadSessionsData];
        [self getNewSessionIfNeeded];      
        [self convertOfflineSessions];
    });
}

- (void)handleApplicationWillTerminate:(NSNotification*) notification 
{
    [self saveSessions];
}

#pragma mark - Dealloc

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    dispatch_release(_backgroundQueue);
    
    SAFE_ARC_RELEASE(_playerId);
    SAFE_ARC_RELEASE(_defaultPlayerId);
    SAFE_ARC_RELEASE(_apiKey);
    SAFE_ARC_RELEASE(_currentSession);
    SAFE_ARC_RELEASE(_allSessions);
    SAFE_ARC_RELEASE(_playerDetails);
    SAFE_ARC_RELEASE(_apiDefinitionsData);
    SAFE_ARC_SUPER_DEALLOC();
}

@end
