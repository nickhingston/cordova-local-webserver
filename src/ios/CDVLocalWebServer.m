/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

#import "CDVLocalWebServer.h"
#import "GCDWebServerPrivate.h"
#import <Cordova/CDVViewController.h>
#import <Cordova/NSDictionary+CordovaPreferences.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <objc/message.h>
#import <netinet/in.h>


#define LOCAL_FILESYSTEM_PATH   @"local-filesystem"
#define ASSETS_LIBRARY_PATH     @"assets-library"
#define ERROR_PATH              @"error"

@interface GCDWebServer()
- (GCDWebServerResponse*)_responseWithContentsOfDirectory:(NSString*)path;
@end


@implementation CDVLocalWebServer

- (void) pluginInitialize {

    BOOL useLocalWebServer = NO;
    BOOL requirementsOK = NO;
    NSString* indexPage = @"index.html";
    NSString* appBasePath = @"www";
    NSUInteger port = 80;

    // check the content tag src
    CDVViewController* vc = (CDVViewController*)self.viewController;
    NSURL* startPageUrl = [NSURL URLWithString:vc.startPage];
    if (startPageUrl != nil) {
        if ([[startPageUrl scheme] isEqualToString:@"http"] && [[startPageUrl host] isEqualToString:@"localhost"]) {
            port = [[startPageUrl port] unsignedIntegerValue];
            useLocalWebServer = YES;
        }
    }

    requirementsOK = [self checkRequirements];
    if (!requirementsOK) {
        useLocalWebServer = NO;
        NSString* alternateContentSrc = [self.commandDelegate.settings cordovaSettingForKey:@"AlternateContentSrc"];
        vc.startPage = alternateContentSrc? alternateContentSrc : indexPage;
    }

    // check setting
#if TARGET_IPHONE_SIMULATOR
    if (useLocalWebServer) {
        NSNumber* startOnSimulatorSetting = [[self.commandDelegate settings] objectForKey:[@"CordovaLocalWebServerStartOnSimulator" lowercaseString]];
        if (startOnSimulatorSetting) {
            useLocalWebServer = [startOnSimulatorSetting boolValue];
        }
    }
#endif
    
    if (port == 0) {
        // CB-9096 - actually test for an available port, and set it explicitly
        port = [self _availablePort];
    }

    NSString* authToken = [NSString stringWithFormat:@"cdvToken=%@", [[NSProcessInfo processInfo] globallyUniqueString]];

    self.server = [[GCDWebServer alloc] init];
    [GCDWebServer setLogLevel:kGCDWebServerLoggingLevel_Error];
	
	// increase the cache size massively!
	int cacheSizeMemory = 64 * 1024 * 1024; // 64MB
	int cacheSizeDisk = 1024 * 1024 * 1024; // 1GB
	NSURLCache* sharedCache = [[NSURLCache alloc] initWithMemoryCapacity:cacheSizeMemory diskCapacity:cacheSizeDisk diskPath:@"nsurlcache"];
	[NSURLCache setSharedURLCache:sharedCache];

    if (useLocalWebServer) {
        [self addAppFileSystemHandler:authToken basePath:[NSString stringWithFormat:@"/%@/", appBasePath] indexPage:indexPage];

        // add after server is started to get the true port
        [self addFileSystemHandlers:authToken];
        [self addErrorSystemHandler:authToken];
        
        // handlers must be added before server starts
        [self.server startWithPort:port bonjourName:nil];

        // Update the startPage (supported in cordova-ios 3.7.0, see https://issues.apache.org/jira/browse/CB-7857)
		vc.startPage = [NSString stringWithFormat:@"http://localhost:%lu/%@/%@?%@", (unsigned long)self.server.port, appBasePath, indexPage, authToken];

    } else {
        if (requirementsOK) {
			// just ignore...
        } else {
            GWS_LOG_ERROR(@"%@ stopped, failed requirements check.", [self.server class]);
        }
    }
}

- (NSUInteger) _availablePort
{
    struct sockaddr_in addr4;
    bzero(&addr4, sizeof(addr4));
    addr4.sin_len = sizeof(addr4);
    addr4.sin_family = AF_INET;
    addr4.sin_port = 0; // set to 0 and bind to find available port
    addr4.sin_addr.s_addr = htonl(INADDR_ANY);

    int listeningSocket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (bind(listeningSocket, (const void*)&addr4, sizeof(addr4)) == 0) {
        struct sockaddr addr;
        socklen_t addrlen = sizeof(addr);
        if (getsockname(listeningSocket, &addr, &addrlen) == 0) {
            struct sockaddr_in* sockaddr = (struct sockaddr_in*)&addr;
            close(listeningSocket);
            return ntohs(sockaddr->sin_port);
        }
    }
    
    return 0;
}

- (BOOL) checkRequirements
{
    NSSet* expectedPluginNames = [NSSet setWithArray:@[@"CDVWKWebViewEngine", @"CDVWKWebViewEngineLocalhost"]];
    
    BOOL hasWkWebView = NSClassFromString(@"WKWebView") != nil;
    NSString* pluginName = [self.commandDelegate.settings cordovaSettingForKey:@"CordovaWebViewEngine"];
    BOOL wkEnginePlugin =  [expectedPluginNames containsObject:pluginName];

    if (!hasWkWebView) {
        NSLog(@"[ERROR] %@: WKWebView class not found in the current runtime version.", [self class]);
    }
    
    if (!wkEnginePlugin) {
        NSLog(@"[ERROR] %@: CordovaWebViewEngine preference must be %@", [self class], pluginName);
    }
    
    return hasWkWebView && wkEnginePlugin;
}

- (NSString*) createErrorUrl:(NSString*)error authToken:(NSString*)authToken
{
    return [NSString stringWithFormat:@"http://localhost:%lu/%@/%@?%@", (unsigned long)self.server.port, ERROR_PATH, [error stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding], authToken];
}

- (void) addProxyToLocalPath:(NSString*) path forServerBaseUrl:(NSURL*) serverBaseUrl andToken:(NSString*) authToken {
    
    GCDWebServerMatchBlock matchBlock = ^GCDWebServerRequest *(NSString* requestMethod, NSURL* requestURL, NSDictionary* requestHeaders, NSString* urlPath, NSDictionary* urlQuery) {
        
        if (![urlPath hasPrefix:path]) {
            return nil;
        }
        
        return [[GCDWebServerDataRequest alloc] initWithMethod:requestMethod url:requestURL headers:requestHeaders path:urlPath query:urlQuery];
    };
    
    GCDWebServerAsyncProcessBlock asyncProcessBlock = ^void (GCDWebServerRequest* request, GCDWebServerCompletionBlock complete) {
        
        //check if it is a request from localhost
        NSString *host = [request.headers objectForKey:@"Host"];
        if (host==nil || [host hasPrefix:@"localhost"] == NO ) {
            complete([GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_Forbidden message:@"FORBIDDEN"]);
            return;
        }
        
        //check if the querystring or the cookie has the token
//		BOOL hasToken = (request.URL.query && [request.URL.query containsString:authToken]);
//		NSString *cookie = [request.headers objectForKey:@"Cookie"];
//		BOOL hasCookie = (cookie && [cookie containsString:authToken]);
//		if (!hasToken && !hasCookie) {
//			complete([GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_Forbidden message:@"FORBIDDEN"]);
//			return;
//		}
        
        NSURLComponents *components = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:YES];
        components.scheme = serverBaseUrl.scheme;
        components.host = serverBaseUrl.host;
        components.port = serverBaseUrl.port;
        
        components.path = [components.path substringFromIndex:[path length]];
        components.path = [serverBaseUrl.path stringByAppendingPathComponent:components.path];
        
        NSMutableURLRequest* nsurlRequest = [NSMutableURLRequest requestWithURL:[components URL]];
        nsurlRequest.HTTPMethod = request.method;
        
        for (NSString* key in [request.headers allKeys]) {
            [nsurlRequest addValue:request.headers[key] forHTTPHeaderField:key];
        }
        
        if (request.hasBody) {
            GCDWebServerDataRequest* dataRequest = (GCDWebServerDataRequest*) request;
            nsurlRequest.HTTPBody = dataRequest.data;
        }
		
		// ensure we use the cache!
		if (!nsurlRequest.allHTTPHeaderFields[@"If-None-Match"]) {
			NSCachedURLResponse* cachedResponse = [[NSURLCache sharedURLCache] cachedResponseForRequest:nsurlRequest];
			if (cachedResponse) {
				NSHTTPURLResponse* httpResponse = (NSHTTPURLResponse*) cachedResponse.response;
				// check cached data is ok?!
				if ([cachedResponse.data length]) {
					NSError* error = nil;
					if (![NSJSONSerialization JSONObjectWithData:cachedResponse.data options:0 error:&error]) {
						// corruption error?
						NSLog(@"Not JSON - clearing the cache! %@", error);
						[[NSURLCache sharedURLCache] removeAllCachedResponses];
					}
					else {
						NSString* etag = httpResponse.allHeaderFields[@"Etag"];
						if ([etag length]) {
							[nsurlRequest addValue:etag forHTTPHeaderField:@"If-None-Match"];
						}
					}
				}
			}
		}
		
        __block NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithRequest:nsurlRequest
                                                                             completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
                                                                                //  NSLog(@"MY TASK: %@", task);
                                                                                //  NSLog(@"MY RESPONSE: %@", response);
                                                                                 NSHTTPURLResponse* httpResponse = (NSHTTPURLResponse*) response;
                                                                                 GCDWebServerResponse* gdcResponse = nil;
                                                                                 if (httpResponse.statusCode >= 200 && httpResponse.statusCode <= 400) {
																					 if (data) {
																						 gdcResponse = [GCDWebServerDataResponse responseWithData:data contentType:httpResponse.allHeaderFields[@"Content-Type"]];
																					 }
																					 else {
																						 // no data
																						 gdcResponse = [GCDWebServerResponse responseWithStatusCode:httpResponse.statusCode];
																					 }
                                                                                     for (NSString* key in httpResponse.allHeaderFields) {
                                                                                         if (![key isEqualToString:@"Content-Encoding"]) {
                                                                                             [gdcResponse setValue:httpResponse.allHeaderFields[key] forAdditionalHeader:key];
                                                                                         }
                                                                                     }
                                                                                     gdcResponse.statusCode = httpResponse.statusCode;
                                                                                 }
                                                                                 else {
                                                                                     gdcResponse = [GCDWebServerResponse responseWithStatusCode:httpResponse.statusCode];
                                                                                 }
                                                                                 
                                                                                 complete(gdcResponse);
                                                                                 
                                                                             }];
        
        [task resume];
    };
    
    [self.server addHandlerWithMatchBlock:matchBlock asyncProcessBlock:asyncProcessBlock];
}

-  (void) addFileSystemHandlers:(NSString*)authToken
{
    // TODO: set in javascript - or config.xml?
    //////////////////////////
//    	[self addProxyToLocalPath:@"/api/" forServerBaseUrl:[NSURL URLWithString:@"http://brix.wearemothership.com:9000/api/"] andToken:authToken];
	// [self addProxyToLocalPath:@"/api/" forServerBaseUrl:[NSURL URLWithString:@"http://192.168.0.130:9000/api/"] andToken:authToken];
	[self addProxyToLocalPath:@"/api/" forServerBaseUrl:[NSURL URLWithString:@"https://vpop-pro.com/api/"] andToken:authToken];
    // //////////////////////
    
    
    [self addLocalFileSystemHandler:authToken];
    [self addAssetLibraryFileSystemHandler:authToken];

    SEL sel = NSSelectorFromString(@"setUrlTransformer:");
    __weak __typeof(self) weakSelf = self;

    if ([self.commandDelegate respondsToSelector:sel]) {
        NSURL* (^urlTransformer)(NSURL*) = ^NSURL* (NSURL* urlToTransform) {
            NSURL* localServerURL = [NSURL URLWithString:[NSString stringWithFormat:@"http://localhost:%lu", (unsigned long)weakSelf.server.port]];
            
            NSURL* transformedUrl = urlToTransform;

            NSString* localhostUrlString = [NSString stringWithFormat:@"http://localhost:%lu", (unsigned long)[localServerURL.port unsignedIntegerValue]];

            if ([[urlToTransform scheme] isEqualToString:ASSETS_LIBRARY_PATH]) {
                transformedUrl = [NSURL URLWithString:[NSString stringWithFormat:@"%@/%@/%@%@",
                                                       localhostUrlString,
                                                       ASSETS_LIBRARY_PATH,
                                                       urlToTransform.host,
                                                       urlToTransform.path
                                                       ]];
                
            } else if ([[urlToTransform scheme] isEqualToString:@"file"]) {
                transformedUrl = [NSURL URLWithString:[NSString stringWithFormat:@"%@/%@%@",
                                                       localhostUrlString,
                                                       LOCAL_FILESYSTEM_PATH,
                                                       urlToTransform.path
                                                       ]];
            }

            return transformedUrl;
        };

        ((void (*)(id, SEL, id))objc_msgSend)(self.commandDelegate, sel, urlTransformer);

    } else {
        NSLog(@"WARNING: CDVPlugin's commandDelegate is missing a urlTransformer property. The local web server can't set it to transform file and asset-library urls");
    }
}

- (void) addFileSystemHandler:(GCDWebServerAsyncProcessBlock)processRequestForResponseBlock basePath:(NSString*)basePath authToken:(NSString*)authToken cacheAge:(NSUInteger)cacheAge
{
    GCDWebServerMatchBlock matchBlock = ^GCDWebServerRequest *(NSString* requestMethod, NSURL* requestURL, NSDictionary* requestHeaders, NSString* urlPath, NSDictionary* urlQuery) {

        if (![requestMethod isEqualToString:@"GET"]) {
            return nil;
        }
        if (![urlPath hasPrefix:basePath]) {
            return nil;
        }
        return [[GCDWebServerRequest alloc] initWithMethod:requestMethod url:requestURL headers:requestHeaders path:urlPath query:urlQuery];
    };

    GCDWebServerAsyncProcessBlock asyncProcessBlock = ^void (GCDWebServerRequest* request, GCDWebServerCompletionBlock complete) {

        //check if it is a request from localhost
        NSString *host = [request.headers objectForKey:@"Host"];
        if (host==nil || [host hasPrefix:@"localhost"] == NO ) {
            complete([GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_Forbidden message:@"FORBIDDEN"]);
        }

        //check if the querystring or the cookie has the token
        BOOL hasToken = (request.URL.query && [request.URL.query containsString:authToken]);
        NSString *cookie = [request.headers objectForKey:@"Cookie"];
        BOOL hasCookie = (cookie && [cookie containsString:authToken]);
        if (!hasToken && !hasCookie) {
            complete([GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_Forbidden message:@"FORBIDDEN"]);
        }

        processRequestForResponseBlock(request, ^void(GCDWebServerResponse* response){
            if (response) {
                response.cacheControlMaxAge = cacheAge;
            } else {
                response = [GCDWebServerResponse responseWithStatusCode:kGCDWebServerHTTPStatusCode_NotFound];
            }

            if (hasToken && !hasCookie) {
                //set cookie
                [response setValue:authToken forAdditionalHeader:@"Set-Cookie"];
            }
            complete(response);
        });
    };

    [self.server addHandlerWithMatchBlock:matchBlock asyncProcessBlock:asyncProcessBlock];
}

- (void) addAppFileSystemHandler:(NSString*)authToken basePath:(NSString*)basePath indexPage:(NSString*)indexPage
{
    BOOL allowRangeRequests = YES;

    NSString* directoryPath = [[self.commandDelegate pathForResource:indexPage] stringByDeletingLastPathComponent];
;

    GCDWebServerAsyncProcessBlock processRequestBlock = ^void (GCDWebServerRequest* request, GCDWebServerCompletionBlock complete) {

        NSString* filePath = [directoryPath stringByAppendingPathComponent:[request.path substringFromIndex:basePath.length]];
        NSString* fileType = [[[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:NULL] fileType];
        GCDWebServerResponse* response = nil;

        if (fileType) {
            if ([fileType isEqualToString:NSFileTypeDirectory]) {
                if (indexPage) {
                    NSString* indexPath = [filePath stringByAppendingPathComponent:indexPage];
                    NSString* indexType = [[[NSFileManager defaultManager] attributesOfItemAtPath:indexPath error:NULL] fileType];
                    if ([indexType isEqualToString:NSFileTypeRegular]) {
                        complete([GCDWebServerFileResponse responseWithFile:indexPath]);
                    }
                }
                response = [self.server _responseWithContentsOfDirectory:filePath];
            } else if ([fileType isEqualToString:NSFileTypeRegular]) {
                if (allowRangeRequests) {
                    response = [GCDWebServerFileResponse responseWithFile:filePath byteRange:request.byteRange];
                    [response setValue:@"bytes" forAdditionalHeader:@"Accept-Ranges"];
                } else {
                    response = [GCDWebServerFileResponse responseWithFile:filePath];
                }
            }
        }

        complete(response);
    };

    [self addFileSystemHandler:processRequestBlock basePath:basePath authToken:authToken cacheAge:0];
}

- (void) addLocalFileSystemHandler:(NSString*)authToken
{
    NSString* basePath = [NSString stringWithFormat:@"/%@/", LOCAL_FILESYSTEM_PATH];
    BOOL allowRangeRequests = YES;

    GCDWebServerAsyncProcessBlock processRequestBlock = ^void (GCDWebServerRequest* request, GCDWebServerCompletionBlock complete) {

        NSString* filePath = [request.path substringFromIndex:basePath.length];
        NSString* fileType = [[[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:NULL] fileType];
        GCDWebServerResponse* response = nil;

        if (fileType && [fileType isEqualToString:NSFileTypeRegular]) {
            if (allowRangeRequests) {
                response = [GCDWebServerFileResponse responseWithFile:filePath byteRange:request.byteRange];
                [response setValue:@"bytes" forAdditionalHeader:@"Accept-Ranges"];
            } else {
                response = [GCDWebServerFileResponse responseWithFile:filePath];
            }
        }

        complete(response);
    };

    [self addFileSystemHandler:processRequestBlock basePath:basePath authToken:authToken cacheAge:0];
}

- (void) addAssetLibraryFileSystemHandler:(NSString*)authToken
{
    NSString* basePath = [NSString stringWithFormat:@"/%@/", ASSETS_LIBRARY_PATH];

    GCDWebServerAsyncProcessBlock processRequestBlock = ^void (GCDWebServerRequest* request, GCDWebServerCompletionBlock complete) {

        NSURL* assetUrl = [NSURL URLWithString:[NSString stringWithFormat:@"assets-library:/%@", [request.path substringFromIndex:basePath.length]]];

        ALAssetsLibrary* assetsLibrary = [[ALAssetsLibrary alloc] init];
        [assetsLibrary assetForURL:assetUrl
                       resultBlock:^(ALAsset* asset) {
                           if (asset) {
                               // We have the asset!  Get the data and send it off.
                               ALAssetRepresentation* assetRepresentation = [asset defaultRepresentation];
                               Byte* buffer = (Byte*)malloc([assetRepresentation size]);
                               NSUInteger bufferSize = [assetRepresentation getBytes:buffer fromOffset:0.0 length:[assetRepresentation size] error:nil];
                               NSData* data = [NSData dataWithBytesNoCopy:buffer length:bufferSize freeWhenDone:YES];
                               NSString* MIMEType = (__bridge_transfer NSString*)UTTypeCopyPreferredTagWithClass((__bridge CFStringRef)[assetRepresentation UTI], kUTTagClassMIMEType);

                               complete([GCDWebServerDataResponse responseWithData:data contentType:MIMEType]);
                           } else {
                               complete(nil);
                           }
                       }
                      failureBlock:^(NSError* error) {
                          NSLog(@"Error: %@", error);
                          complete(nil);
                      }
         ];
    };

    [self addFileSystemHandler:processRequestBlock basePath:basePath authToken:authToken cacheAge:0];
}

- (void) addErrorSystemHandler:(NSString*)authToken
{
    NSString* basePath = [NSString stringWithFormat:@"/%@/", ERROR_PATH];

    GCDWebServerAsyncProcessBlock processRequestBlock = ^void (GCDWebServerRequest* request, GCDWebServerCompletionBlock complete) {

        NSString* errorString = [request.path substringFromIndex:basePath.length]; // error string is from the url path
        NSString* html = [NSString stringWithFormat:@"<h1 style='margin-top:40px; font-size:6vw'>ERROR</h1><h2 style='font-size:3vw'>%@</h2>", errorString];
        GCDWebServerResponse* response = [GCDWebServerDataResponse responseWithHTML:html];
        complete(response);
    };

    [self addFileSystemHandler:processRequestBlock basePath:basePath authToken:authToken cacheAge:0];
}


@end
