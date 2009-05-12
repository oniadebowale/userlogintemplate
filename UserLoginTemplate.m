#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <Collaboration/Collaboration.h>

#include <asl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>
#include <sys/xattr.h>

#include <sys/types.h>
#include <sys/acl.h>

// Inspired by Peter Hosey's series on asl_log
#ifndef ASL_KEY_FACILITY
#   define ASL_KEY_FACILITY "Facility"
#endif

/*
 ASL_LEVEL_EMERG   0
 ASL_LEVEL_ALERT   1
 ASL_LEVEL_CRIT    2
 ASL_LEVEL_ERR     3
 ASL_LEVEL_WARNING 4
 ASL_LEVEL_NOTICE  5
 ASL_LEVEL_INFO    6
 ASL_LEVEL_DEBUG   7
 */

#define LOG_LEVEL_TO_PRINT ASL_LEVEL_DEBUG

#define NSLog_level(log_level, format, ...) asl_log(NULL, NULL, log_level, "%s", [[NSString stringWithFormat:format, ##__VA_ARGS__] UTF8String]); if (log_level <= LOG_LEVEL_TO_PRINT) { if (log_level < ASL_LEVEL_WARNING) { fprintf(stderr, "Error: %s\n", [[NSString stringWithFormat:format, ##__VA_ARGS__] UTF8String]); } else { printf("%s\n", [[NSString stringWithFormat:format, ##__VA_ARGS__] UTF8String]); } }

#define NSLog_emerg(format, ...) NSLog_level(ASL_LEVEL_EMERG, format, ##__VA_ARGS__)
#define NSLog_alert(format, ...) NSLog_level(ASL_LEVEL_ALERT, format, ##__VA_ARGS__)
#define NSLog_crit(format, ...) NSLog_level(ASL_LEVEL_CRIT, format, ##__VA_ARGS__)
#define NSLog_error(format, ...) NSLog_level(ASL_LEVEL_ERR, format, ##__VA_ARGS__)
#define NSLog_warn(format, ...) NSLog_level(ASL_LEVEL_WARNING, format, ##__VA_ARGS__)
#define NSLog_notice(format, ...) NSLog_level(ASL_LEVEL_NOTICE, format, ##__VA_ARGS__)
#define NSLog_info(format, ...) NSLog_level(ASL_LEVEL_INFO, format, ##__VA_ARGS__)
#define NSLog_debug(format, ...) NSLog_level(ASL_LEVEL_DEBUG, format, ##__VA_ARGS__)

enum status_codes {
	status_sucess,
	internal_error,
	file_missing,
	file_permissions_error,
	file_format_error,
	setup_error,
	preference_missing,
	preference_error
};

enum resultErrorCodes {
	result_sucess,
	result_preference_error,
	result_setup_error
};

#pragma mark Hard settings
// these settings are never changed in run-time

NSString * applicationDomain			= @"org.larkost.userlogintemplate"; // can't use NSBundle value because we have no bundle

NSString * testingFolderName			= @"testing";
NSString * testingHomeFolderName		= @"home";
NSString * testingTemplateFolderName	= @"template";
NSString * testingOtherFolderName		= @"other";

#pragma mark Defaults
// all override-able from the preference file
#pragma mark TODO: put these all in the preference section
NSString * movedAsideSuffix				= @"MOVED_ASIDE"; // appended to files that have been moved asside
NSString * replacePrefix				= @"REPLACE_"; // appeneded to the replacement string for all interal path translations

BOOL testingMode						= TRUE;

#pragma mark Internal variables
NSString * userName						= nil;
NSString * homeDirectory				= nil;
uid_t userId;

NSString * templateSourcePath			= nil;

NSString * byHostIDString				= nil;
NSString * byHostImageName				= nil;

NSMutableDictionary * rootOwnedFolders	= nil;
NSMutableDictionary * userOwnedFolders	= nil;

NSMutableDictionary * pathTranslations	= nil;
NSMutableDictionary * replacedItems		= nil;

NSFileManager * fileManager				= nil;

NSString * testingFolderPath			= nil;

NSString * translatePathAndAddPrefix (NSString * workingPath, BOOL addPrefix) {
	if (workingPath == nil) {
		return workingPath;
	}
	
	for (NSString * beforeString in pathTranslations) {
		NSRange workingRange = [workingPath rangeOfString:beforeString];
		int recursionCounter = 0; // keep this from infinite recursion
		while (workingRange.location != NSNotFound && recursionCounter < 10) {
			workingPath = [workingPath stringByReplacingCharactersInRange:workingRange withString:[pathTranslations objectForKey:beforeString]];
			
			workingRange = [workingPath rangeOfString:beforeString];
			recursionCounter += 1;
		}
	}
	
	if (![workingPath hasPrefix:@"/"] && addPrefix) {
		if ([homeDirectory hasSuffix:@"/"]) {
			workingPath = [homeDirectory stringByAppendingString:workingPath];
		} else {
			workingPath = [[homeDirectory stringByAppendingString:@"/"] stringByAppendingString:workingPath];
		}
	}
	
	// Note: we are not explicitly retaining the string, so it is the callers responsibility
	return workingPath;
}

NSString * translatePath (NSString * workingPath) {
	return translatePathAndAddPrefix(workingPath, TRUE);
}

int createFolders (NSArray * folders, NSDictionary * folderAttributes) {
	BOOL isFolder;
	NSError * setupError;
	
	for (NSString * folderPath in folders) {
		if ([fileManager fileExistsAtPath:folderPath isDirectory:&isFolder] == TRUE) {
			if (!isFolder) {
				NSLog_error(@"Cound not create folder because a non-folder item already exists at path: %@", folderPath);
				return setup_error;
			}
			// make sure that the permissions are all correct
			if ([fileManager changeFileAttributes:folderAttributes atPath:folderPath] == FALSE) {
				NSLog_warn(@"	Unable to set file attributes on existing folder: %@", folderPath);
			} else {
				NSLog_debug(@"	Folder already exists: %@", folderPath);
			}
			// if there are any acl's on it, kill them
			#pragma mark Remove ACLs
			
		} else {
			if ([fileManager createDirectoryAtPath:folderPath withIntermediateDirectories:YES attributes:folderAttributes error:&setupError] == FALSE) {
				NSLog_error(@"Got an error creating folder at path: %@", folderPath);
				return setup_error;
			}
			NSLog_debug(@"	Created folder at: %@", folderPath);
		}
	}
	return status_sucess;
}

int readPreferences () {
	NSLog_info(@"Reading Preferences");
		
	#pragma mark Get testing folder
	if (testingMode) {
		NSArray * testingFolderPathSplit = [[[NSBundle mainBundle] executablePath] pathComponents];
		testingFolderPath = [[NSString pathWithComponents:[testingFolderPathSplit subarrayWithRange: NSMakeRange(0, [testingFolderPathSplit count] - 3)]] stringByAppendingPathComponent:testingFolderName];
		
		homeDirectory = [testingFolderPath stringByAppendingPathComponent:testingHomeFolderName];
		NSLog_notice(@"	Testing: adjusted home folder: %@", homeDirectory);
	}
	
	#pragma mark Get preference file
	NSString * preferencesLocation;
	if (testingMode) {
		preferencesLocation = [testingFolderPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", applicationDomain]];
		NSLog_notice(@"	Testing: adjusted preferences location: %@", preferencesLocation);
	} else {
		preferencesLocation = [@"/Library/Preferences" stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", applicationDomain]];
		NSLog_debug(@"	Preferences Location: %@", preferencesLocation);
	}
	
	NSMutableDictionary * inputPreferences = [NSMutableDictionary dictionaryWithContentsOfFile:preferencesLocation];
	if (inputPreferences == nil) {
		NSLog_error(@"Preference file missing or unreadable at: %@", preferencesLocation);
		return file_missing;
	}
	
	NSString * preferenceString				= nil;
	NSDictionary * preferenceDictionary		= nil;
//	NSArray * preferenceArray				= nil;
	
	#pragma mark Set variables
	
	#pragma mark - template source
	if ((preferenceString = (NSString *)[inputPreferences objectForKey:@"Template Source"]) == nil) {
		NSLog_error(@"Missing Template Source Location preference");
		return preference_missing;
	}
	if (testingMode) {
		templateSourcePath = [testingFolderPath stringByAppendingPathComponent:testingTemplateFolderName];
		NSLog_notice(@"	Testing: adjusted template source location: %@", preferencesLocation);
	} else {
		NSLog_debug(@"	Template Source:	%@", preferenceString);
		templateSourcePath = [preferenceString retain];
	}
	
	#pragma mark - root and user owned folders
	struct folder {
		NSString * name;
		NSMutableDictionary * dict;
	};
	struct folder folders[] = {
		{ @"Root Owned Folders", rootOwnedFolders },
		{ @"User Owned Folders", userOwnedFolders }
	};
	for (int i = 0; i < sizeof(folders)/sizeof(struct folder); i++) {
		NSMutableDictionary * thisFolderDictionary = folders[i].dict;
		NSString * thisFolderName = folders[i].name;
		
		if ((preferenceDictionary = (NSDictionary *)[inputPreferences objectForKey:thisFolderName]) == nil) {
			NSLog_notice(@"	No %@ preference item", thisFolderName);
		} else if ([[preferenceDictionary class] isSubclassOfClass:[NSDictionary class]] == FALSE) {
			NSLog_notice(@"	%@ item is not a dictionary", thisFolderName);
		} else {
			for (preferenceString in preferenceDictionary) {
				NSString * folderPath = [preferenceDictionary objectForKey:preferenceString];
				if ([[folderPath class] isSubclassOfClass:[NSString class]] == FALSE) {
					NSLog_warn(@"	Bad item in %@ preferences: %@", thisFolderName, preferenceString);
					continue;
				}
				
				[thisFolderDictionary setObject:folderPath forKey:preferenceString];
				if ([pathTranslations objectForKey:preferenceString]) {
					NSLog_warn(@"	Already an object in translated paths for key: %@ (%@)", preferenceString, thisFolderName)
					continue;
				}
				
				[pathTranslations setObject:folderPath forKey:preferenceString];
				NSLog_debug(@"	Added untranslated path to %@: %@ for key: %@", thisFolderName, folderPath, preferenceString);
			}
		}
	}
	
	#pragma mark - image byhost name
	if ((preferenceString = (NSString *)[inputPreferences objectForKey:@"ByHost Image Name"]) == nil) {
		NSLog_debug(@"	No Image Name");
	} else {
		NSLog_debug(@"	ByHost Image Name:	%@", preferenceString);
		byHostImageName = preferenceString;
	}
	
	#pragma mark Additional path translations
	if ((preferenceDictionary = (NSDictionary *)[inputPreferences objectForKey:@"Path Translations"]) != nil && [[preferenceDictionary class] isSubclassOfClass:[NSDictionary class]]) {
		for (NSString * preferenceString in preferenceDictionary) {
			if ([[[preferenceDictionary objectForKey:preferenceString] class] isSubclassOfClass:[NSString class]] == FALSE) {
				NSLog_debug(@"	Path translation item: '%@' is not a string!");
				continue;
			}
			NSLog_debug(@"	Path translation: %@ -> %@", preferenceString, [preferenceDictionary objectForKey:preferenceString]);
			[pathTranslations setValue:[preferenceDictionary objectForKey:preferenceString] forKey:preferenceString];
		}
	}
	
	return status_sucess;
}

int setupPathTranslations () {
	#pragma mark Add built-in values
	NSLog_debug(@"Setting Up Path Translations");
	
	#pragma mark - user name
	[pathTranslations setObject:userName forKey:[replacePrefix stringByAppendingString:@"USER_NAME"]];
	
	#pragma mark - home directory
	[pathTranslations setObject:homeDirectory forKey:[replacePrefix stringByAppendingString:@"HOME_DIRECTORY"]];
	
	#pragma mark - byhost ID
	io_struct_inband_t iokit_entry;
	uint32_t bufferSize = 4096;
	io_registry_entry_t ioRegistryRoot = IORegistryEntryFromPath(kIOMasterPortDefault, "IOService:/");
	IORegistryEntryGetProperty(ioRegistryRoot, kIOPlatformUUIDKey, iokit_entry, &bufferSize);
	byHostIDString = [NSString stringWithCString:iokit_entry encoding:NSASCIIStringEncoding];
	// older comptuers use only the mac address portion of the UUID string
	if ([byHostIDString hasPrefix:@"00000000-0000-1000-8000-"]) {
		NSArray * UUIDElements = [byHostIDString componentsSeparatedByString:@"-"];
		byHostIDString = [(NSString *)[UUIDElements objectAtIndex:[UUIDElements count] -1] lowercaseString];
	}
	IOObjectRelease((unsigned int) iokit_entry);
	IOObjectRelease(ioRegistryRoot);
	[pathTranslations setObject:byHostIDString forKey:[replacePrefix stringByAppendingString:@"BYHOST_KEY"]];
	
	#pragma mark - user temporary directory
	if (getuid() == 0) {
		// a quick jaunt into the user's space, then back
		seteuid(userId);
	}
	[pathTranslations setObject:NSTemporaryDirectory() forKey:[replacePrefix stringByAppendingString:@"USER_TEMP_DIR"]];
	if (getuid() == 0) {
		seteuid(0);
	}
	
	#pragma mark - tesing other directory
	[pathTranslations setObject:[testingFolderPath stringByAppendingPathComponent:testingOtherFolderName] forKey:[replacePrefix stringByAppendingString:@"TESTING_OTHER"]];
	
	#pragma mark Check each path translation to see if it has the others in it
	NSArray * pathTranslationKeys = [pathTranslations allKeys];
	// note that this only will deal with one level, no recursion
	for (int i = 0; i < 3; i++) {
		for (NSString * outerIterator in pathTranslationKeys) {
			for (NSString * innerIterator in pathTranslationKeys) {
				if ([outerIterator isEqualToString:innerIterator]) { continue; } // can't be inside itself
				
				NSString * workingValue = [pathTranslations objectForKey:outerIterator];
				if (workingValue == nil || [workingValue isEqualToString:@""]) {
					NSLog_error(@"The value for the path translation: %@ is empty", outerIterator);
					continue;
				}
				
				if ([workingValue rangeOfString:innerIterator].location != NSNotFound) {
					[pathTranslations setObject:[workingValue stringByReplacingOccurrencesOfString:innerIterator withString:[pathTranslations objectForKey:innerIterator]]  forKey:outerIterator];
				}
			}
		}
	}
	
	for (NSString * thisKey in pathTranslations) {
		NSLog_debug(@"	%@:	%@", thisKey, [pathTranslations objectForKey:thisKey]);
	}
	
	#pragma mark Sync translated user and root folder paths
	for (NSString * key in rootOwnedFolders) {
		[rootOwnedFolders setObject:[pathTranslations objectForKey:key] forKey:key];
	}
	for (NSString * key in userOwnedFolders) {
		[userOwnedFolders setObject:[pathTranslations objectForKey:key] forKey:key];
	}

	return result_sucess;
}


int mergeArray (NSMutableArray * sourceArray, NSArray * templateArray) {
	
	return result_sucess;
}

int mergeDictionary (NSMutableDictionary * sourceDict, NSDictionary * templateDict) {
	if (sourceDict == nil || templateDict == nil) {
		NSLog_error(@"Source or template dictionary was nil");
		return internal_error;
	}
	
	for (NSString * key in templateDict) {
		NSObject * templateItem = [templateDict objectForKey:key];
		NSObject * sourceItem = [sourceDict objectForKey:key];
		
		if (sourceItem == nil) {
			// since there is no conflict we can just copy it into place
			[sourceDict setObject:templateItem forKey:key];
		} else if ([[sourceItem class] isSubclassOfClass:[templateItem class]] == FALSE) {
			// the one in the home folder is probably bad, so we are just going to replace it
			[sourceDict setObject:templateItem forKey:key];
		} else if ([[templateItem class] isSubclassOfClass:[NSDictionary class]]) {
		} else if ([[templateItem class] isSubclassOfClass:[NSArray class]]) {
		} else {
			// this is one of the flat data types, and there is nothing to do but copy them in
			
		}

	}
	
	return result_sucess;
}

int mergePlists (NSString * targetPlist, NSString * templatePlist) {
	// merge one plist into another existing plist
	
	id sourceItem; // we will use this as the destination
	id templateItem;
	
	NSPropertyListFormat sourceFormat;
	
	NSString * errorString;
	
	// get the source item
	NSData * plistData = [NSData dataWithContentsOfFile:targetPlist];
	if (plistData == nil) {
		NSLog_error(@"Plist source file was corrupt or missing: %@", targetPlist);
		return file_missing;
	}
	sourceItem = [NSPropertyListSerialization propertyListFromData:plistData mutabilityOption:NSPropertyListMutableContainers format:&sourceFormat errorDescription:&errorString];
	if (sourceItem == nil) {
		NSLog_error(@"Plist source file was corrupt: %@", targetPlist);
		return file_format_error;
	} else if (errorString != nil) {
		NSLog_error(@"Plist source file was corrupt: %@ (%@)", targetPlist, errorString);
		[errorString release];
		return file_format_error;
	}
	
	// get the template item
	plistData = [NSData dataWithContentsOfFile:templatePlist];
	if (plistData == nil) {
		NSLog_error(@"Plist template file was corrupt or missing: target %@", templatePlist);
		return file_missing;
	}
	templateItem = [NSPropertyListSerialization propertyListFromData:plistData mutabilityOption:NSPropertyListMutableContainers format:NULL errorDescription:&errorString];
	if (sourceItem == nil) {
		NSLog_error(@"Plist source file was corrupt: %@", templatePlist);
		return file_format_error;
	} else if (errorString != nil) {
		NSLog_error(@"Plist source file was corrupt: %@ (%@)", templatePlist, errorString);
		[errorString release];
		return file_format_error;
	}
	
	if ([[sourceItem class] isSubclassOfClass:[templateItem class]] == NO) {
		NSLog_error(@"Source and template plists don't have the same type of root: %@ and %@", targetPlist, templatePlist);
		return file_format_error;
	}
	
	if ([[sourceItem class] isSubclassOfClass:[NSDictionary class]]) {
		// root is a dictionary
		if (mergeDictionary((NSMutableDictionary *)sourceItem, (NSDictionary *)templateItem) == result_sucess) {
			NSLog_debug(@"		Plist is in dictionary format: %@", templatePlist);
		}
	} else if ([[sourceItem class] isSubclassOfClass:[NSArray class]]) {
		// root is an array
		if (mergeArray((NSMutableArray *)sourceItem, (NSArray *)templateItem) == result_sucess) {
			NSLog_debug(@"		Plist is in array format: %@", templatePlist);
		}
	} else {
		NSLog_error(@"The plists are in an unexpected format: %@", templatePlist);
		return file_format_error;
	}
	
	plistData = [NSPropertyListSerialization dataFromPropertyList:sourceItem format:sourceFormat errorDescription:&errorString];
	if (plistData == nil) {
		NSLog_error(@"Unable to sealize plist: %@", templatePlist);
		return internal_error;
	} else if (errorString != nil) {
		NSLog_error(@"Unable to sealize plist: %@ got message: %@", templatePlist, errorString);
		[errorString release];
		return internal_error;
	}
	if ([plistData writeToFile:targetPlist atomically:YES]) {
		NSLog_debug(@"		Plist written back out at: %@", targetPlist);
	} else {
		NSLog_error(@"Unable to write plist: %@", targetPlist)
	}
	
	return result_sucess;
}

int moveFileAsside (NSString * targetFilePath) {
	int counter = 1;
	NSString * workingPath = [targetFilePath stringByAppendingPathExtension:movedAsideSuffix];
	
	while ([fileManager fileExistsAtPath:workingPath]) {
		counter += 1;
		workingPath = [targetFilePath stringByAppendingPathExtension:[movedAsideSuffix stringByAppendingFormat:@"-%i", counter]];
	}
	
	if ([fileManager movePath:targetFilePath toPath:workingPath handler:nil] == NO) {
		NSLog_warn(@"Unable move asside file at: %@", targetFilePath);
		return file_permissions_error;
	}
	
	// add this to the moved file list so it can be undone
	[replacedItems setObject:targetFilePath forKey:workingPath];
	
	return status_sucess;
}

int copyFileIntoPlace (NSString * sourcePath, NSString * sourceType, NSString * destinationPath) {
	// here we assume that the file does not exist
	NSError * creationError;
	
	if ([sourceType isEqualToString:NSFileTypeDirectory]) {
		// create the directory
		if ([fileManager createDirectoryAtPath:destinationPath attributes:nil] == FALSE) {
			NSLog_error(@"Unable to create directory at %@", destinationPath);
			return file_permissions_error; // we are assuming it was a permissions error
		}
		NSLog_debug(@"		Created directory at: %@", destinationPath);
		
	} else if ([sourceType isEqualToString:NSFileTypeRegular]) {
		// copy the file into place 
		if ([fileManager copyItemAtPath:sourcePath toPath:destinationPath error:&creationError] == NO) {
			NSLog_error(@"Unable to copy: %@ to: %@", sourcePath, destinationPath);
			return file_permissions_error; // we are assuming it was a permissions error
		}
		NSLog_debug(@"		Copied: %@ to: %@", sourcePath, destinationPath);
		
	} else if ([sourceType isEqualToString:NSFileTypeSymbolicLink]) {
		// for symbolic links we have to also translate the path of the link
		NSString * translatedLinkPath = [fileManager pathContentOfSymbolicLinkAtPath:sourcePath];
		if (translatedLinkPath == nil) {
			NSLog_error(@"Unable to read link destination of: %@", sourcePath);
			return file_permissions_error; // we are assuming it was a permissions error
		}
		translatedLinkPath = translatePathAndAddPrefix(translatedLinkPath, FALSE);
		if ([fileManager createSymbolicLinkAtPath:destinationPath pathContent:translatedLinkPath] == FALSE) {
			NSLog_error(@"Unable to create link at: %@", destinationPath);
			return file_permissions_error; // we are assuming it was a permissions error
		}
		NSLog_debug(@"	Created link at: %@ pointing at: %@", destinationPath, translatedLinkPath);
		
	} else {
		NSLog_error(@"copyFileIntoPlace recieved a bad type: %@", sourceType);
		return internal_error;
	}


		
	return status_sucess;
}

int main (int argc, const char * argv[]) {
    NSAutoreleasePool * pool		= [[NSAutoreleasePool alloc] init];
	
	#pragma mark Setup
	
	#pragma mark  - global vaiables
	pathTranslations	= [[NSMutableDictionary dictionary] retain];
	replacedItems		= [[NSMutableDictionary dictionary] retain];
	fileManager			= [[NSFileManager defaultManager] retain];
	
	rootOwnedFolders	= [[NSMutableDictionary dictionary] retain];
	userOwnedFolders	= [[NSMutableDictionary dictionary] retain];
	
	#pragma mark  - user information
	NSLog_notice(@"Getting user information");
	CSIdentityQueryRef query;
	CFErrorRef error;
	CFArrayRef identityArray;
	CSIdentityRef userIdentity;
	
	if (getuid() == 0) {
		if (argc == 1) {
			NSLog_error(@"When running as root a single user-name must be supplied on the command line. Exiting");
			return preference_error;
		} else if (argc > 2) {
			NSLog_error(@"When running as root only a sigle argument allowed (user name or UID). Exiting");
			return preference_error;
		}

		NSString * userArgument = [NSString stringWithCString:argv[1] encoding:NSUTF8StringEncoding];
		
		// try argv[1] as a user name
		query = CSIdentityQueryCreateForName(kCFAllocatorDefault, (CFStringRef)userArgument, kCSIdentityQueryStringEquals, kCSIdentityClassUser, CSGetDefaultIdentityAuthority());
		if (CSIdentityQueryExecute(query, kCSIdentityQueryGenerateUpdateEvents, &error)) {
				identityArray = CSIdentityQueryCopyResults(query);
				if (CFArrayGetCount(identityArray) == 1) {
					// we found it, and can pass through
					NSLog_info(@"	Found user with name: %@", userArgument);
					userIdentity = (CSIdentityRef)CFArrayGetValueAtIndex(identityArray, 0);
				} else if (CFArrayGetCount(identityArray) > 1) {
					// we got more than one result
					NSLog_error(@"Found more than one user when searching for the name %@, unable to continue.", userArgument);
					CFRelease(identityArray);
					CFRelease(query);
					return preference_error;
				} else {
					CFRelease(query);
					
					// no results, so we should try argv[1] as a uid
					query = CSIdentityQueryCreateForPosixID(kCFAllocatorDefault, (id_t)[userArgument intValue], kCSIdentityClassUser, CSGetDefaultIdentityAuthority());
					if (CSIdentityQueryExecute(query, kCSIdentityQueryGenerateUpdateEvents, &error)) {
						if (CFArrayGetCount(identityArray) == 1) {
							// we found it, and can pass through
							userIdentity = (CSIdentityRef)CFArrayGetValueAtIndex(identityArray, 0);
							NSLog_info(@"	Found user with uid: %@", userArgument);
						} else if (CFArrayGetCount(identityArray) > 1) {
							// we got more than one result
							NSLog_error(@"Found more than one user when searching for the uid %@, unable to continue.", userArgument);
							CFRelease(identityArray);
							CFRelease(query);
							return preference_error;
						} else {
							// there was no user that matched the information given
							NSLog_error(@"Unable to find a user with the name or uid %@, unable to continue.", userArgument);
							CFRelease(identityArray);
							CFRelease(query);
							return preference_error;
						}
					} else {
						NSLog_error(@"Unable to querry the user database! Exiting.");
						CFRelease(identityArray);
						CFRelease(query);
						return internal_error;
					}
				}
		} else {
			NSLog_error(@"Unable to querry the user database! Exiting.");
			CFRelease(query);
			return internal_error;
		}
		CFRelease(query);
	
	} else {
		// we are running as non-root, so this should be the user
		if (argc != 1) {
			NSLog_error(@"When running as a user other than root no arguments are required/permitted. Exiting");
			return preference_error;
		}
		
		query = CSIdentityQueryCreateForCurrentUser(kCFAllocatorDefault);
		if (CSIdentityQueryExecute(query, kCSIdentityQueryGenerateUpdateEvents, &error)) {
			identityArray = CSIdentityQueryCopyResults(query);
			if (CFArrayGetCount(identityArray) == 1) {
				// success
				userIdentity = (CSIdentityRef)CFArrayGetValueAtIndex(identityArray, 0);
				NSLog_info(@"	Using current user");
			} else {
				NSLog_error(@"Unable to get the current user. Exiting");
				CFRelease(identityArray);
				CFRelease(query);
				return internal_error;
			}
		} else {
			NSLog_error(@"Unable to get the current user. Exiting");
			CFRelease(identityArray);
			CFRelease(query);
			return internal_error;
		}
		CFRelease(query);
	}
	
	userName = [(NSString *)CSIdentityGetPosixName(userIdentity) retain];
	userId = CSIdentityGetPosixID(userIdentity);
	homeDirectory = [NSHomeDirectoryForUser(userName) retain];
	
	CFRelease(identityArray); // takes care of userIdentity
	
	NSLog_notice(@"	Setting user: %@ uid: %i home folder: %@", userName, userId, homeDirectory);
	
	#pragma mark - preferences
	if (readPreferences(argc, argv) != result_sucess) {
		return result_preference_error;
	}
	
	#pragma mark - path translations
	if (setupPathTranslations() != result_sucess) {
		return result_setup_error;
	}
	
	#pragma mark Validate settings
	NSLog_info(@"Validating Preferences");
	BOOL isDirectory;
	
	#pragma mark - home folder
	if (homeDirectory == nil) {
		NSLog_error(@"User does not have a home directory set");
		return preference_error;
	}
	if ([homeDirectory isEqualToString:@"/var/empty"]) {
		NSLog_debug(@"		User has an invalid home directory: %@", homeDirectory);
		return preference_error;
	}
	if ([fileManager fileExistsAtPath:homeDirectory isDirectory:&isDirectory]) {
		if (!isDirectory) {
			NSLog_error(@"User home directory path is not a folder: %@", homeDirectory);
			return preference_error;
		}
		NSLog_debug(@"	Home directory looks ok: %@", homeDirectory);
	} else {
		NSLog_error(@"The users home directly for the user does not exit: %@", homeDirectory);
		return preference_error;
	}
	
	#pragma mark - template source
	if (templateSourcePath == nil) {
		NSLog_error(@"No template source set");
		return preference_error;
	}
	if ([fileManager fileExistsAtPath:templateSourcePath isDirectory:&isDirectory]) {
		if (!isDirectory) {
			NSLog_error(@"Template source path is not a folder: %@", templateSourcePath);
			return preference_error;
		}
		NSLog_debug(@"	Template source path ok: %@", templateSourcePath);
	} else {
		NSLog_error(@"Template source path does not exit: %@", templateSourcePath);
		return preference_error;
	}

	NSDictionary * folderAttributes;
	
	#pragma mark Root actions
		
	#pragma mark - root folders
	// Setup folders that need to be shared by multiple users, this should be done as root if possible
	NSLog_notice(@"Creating root folders");
	if (getuid() == 0) {
		folderAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
			@"root", NSFileOwnerAccountName,
			@"wheel", NSFileGroupOwnerAccountName,
			[NSNumber numberWithInt:(S_ISVTX | S_IRWXU | S_IRWXG | S_IRWXO)], NSFilePosixPermissions,
			NULL
		];
	} else {
		folderAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
			[NSNumber numberWithInt:(S_ISVTX | S_IRWXU | S_IRWXG | S_IRWXO)], NSFilePosixPermissions,
			NULL
		];
	}
	if (createFolders([rootOwnedFolders allValues], folderAttributes) != status_sucess) {
		return setup_error;
	}
	
	#pragma mark Change to user
	// don't want any chance that we have root permissions, and can change off-limits things
	if (getuid() == 0) {
		seteuid(userId);
	}
	
	#pragma mark User actions
	
	#pragma mark - user folders
	// Setup folders that should be owned by the user
	NSLog_notice(@"Creating user folders");
	folderAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
		[NSNumber numberWithInt:(S_IRWXU)], NSFilePosixPermissions, // only allow user anything
		NULL
	];
	if (createFolders([userOwnedFolders allValues], folderAttributes) != status_sucess) {
		return setup_error;
	}
	
	#pragma mark - byhost image preferences
	if (byHostImageName != nil) {
		NSLog_notice(@"ByHost user folders");
		NSString * byHostPath = [homeDirectory stringByAppendingPathComponent:@"Library/Preferences/ByHost"];
		BOOL isFolder;
		if ([fileManager fileExistsAtPath:byHostPath isDirectory:&isFolder] == TRUE) {
			if (isFolder == TRUE) {
				for (NSString * directoryItem in [fileManager directoryContentsAtPath:byHostPath]) {
					if ([directoryItem rangeOfString:byHostImageName].location != NSNotFound) {
						
						NSLog_debug(@"	Mergeing ByHost Item: %@", directoryItem);
						
						NSString * translatedDirectoryItem = [byHostPath stringByAppendingPathComponent:[directoryItem stringByReplacingOccurrencesOfString:byHostImageName withString:byHostIDString]];
						
						if ([fileManager fileExistsAtPath:translatedDirectoryItem] == TRUE) {
							mergePlists([byHostPath stringByAppendingPathComponent:directoryItem], translatedDirectoryItem);
						} else {
							copyFileIntoPlace([byHostPath stringByAppendingPathComponent:directoryItem], NSFileTypeRegular, translatedDirectoryItem);
						}
					}
				}
				
			} else {
				NSLog_warn(@"Object at ByHost folder location is not a folder: %@", byHostPath);
			}

		} else {
			NSLog_debug(@"ByHost folder does not exist in the user home folder: %@", homeDirectory);
		}

	}
	
	#pragma mark Iterate over the template folder
	NSLog_debug(@"Iterating over the user template folder");
	NSDirectoryEnumerator * enumerator		= [fileManager enumeratorAtPath:templateSourcePath];
	NSAutoreleasePool * innerPool			= [[NSAutoreleasePool alloc] init];
	NSString * sourceFile;
	int poolCount		= 0;
	while (sourceFile = [enumerator nextObject]) {
		NSString * templateFilePath;
		if (! [sourceFile isAbsolutePath]) {
			templateFilePath = [templateSourcePath stringByAppendingPathComponent:sourceFile];
		} else {
			templateFilePath = sourceFile;
		}
		
		NSString * templateFileType			= [[fileManager fileAttributesAtPath:templateFilePath traverseLink:NO] fileType];
		
		NSString * targetFilePath			= translatePath(sourceFile);
		NSString * targetFileType			= [[fileManager fileAttributesAtPath:targetFilePath traverseLink:NO] fileType];
		NSString * targetFileTypeTraversed	= [[fileManager fileAttributesAtPath:targetFilePath traverseLink:YES] fileType];
		
		// Note: this needs to be in sync with the other version of this
		NSArray * useableTemplateFileTypes		= [NSArray arrayWithObjects: NSFileTypeRegular, NSFileTypeDirectory, NSFileTypeSymbolicLink, nil];
		
		if (templateFileType == nil) {
			NSLog_error(@"Source file does not have a file type: %@", sourceFile);
			
		} else if ([useableTemplateFileTypes containsObject:templateFileType] && [fileManager fileExistsAtPath:targetFilePath] == FALSE) {
			#pragma mark - missing files
			// create it
			NSLog_debug(@"	%@ %@ does not exist", templateFileType, targetFilePath);
			copyFileIntoPlace(templateFilePath, templateFileType, targetFilePath);
		} else if ([templateFileType isEqualToString:NSFileTypeSymbolicLink]) {
			#pragma mark - symlinks
			NSString * translatedTemplateDestination = translatePathAndAddPrefix([fileManager pathContentOfSymbolicLinkAtPath:templateFilePath], FALSE);
			
			if ([targetFileType isEqualToString:templateFileType] && [translatedTemplateDestination isEqualToString:[fileManager pathContentOfSymbolicLinkAtPath:targetFilePath]]) {
				// already correct
				NSLog_debug(@"	%@ already exists at: %@", templateFileType, targetFilePath);
			} else {
				if (moveFileAsside(targetFilePath) == status_sucess) {
					copyFileIntoPlace(templateFilePath, templateFileType, targetFilePath);
					NSLog_debug(@"	Moved aside and replaced  %@ at: %@", templateFileType, targetFilePath);
				}
			}
		} else if ([templateFileType isEqualToString:NSFileTypeRegular] && [[[templateFilePath pathExtension] lowercaseString] isEqualToString:@"plist"]) {
			#pragma mark - plists
			
			if (mergePlists(targetFilePath, templateFilePath) == result_sucess) {
				// should have written out sucess message
			} else {
				// should have already printed an error message
			}

		} else if ([useableTemplateFileTypes containsObject:templateFileType]) {
			#pragma mark - regular files and directories
			if ([targetFileTypeTraversed isEqualToString:templateFileType]) {
				// if the file is already there, leave it alone
				NSLog_debug(@"	%@ already exists at: %@", templateFileType, targetFilePath);
			} else {
				// move the file asside
				if (moveFileAsside(targetFilePath) == status_sucess) {
					copyFileIntoPlace(templateFilePath, templateFileType, targetFilePath);
					NSLog_debug(@"	Moved aside and replaced  %@ at: %@", templateFileType, targetFilePath);
				}
			}
		} else {
			// Other
			NSLog_error(@"%@ is an unsupported type: %@", sourceFile, templateFileType);
		}

		// movedAsideSuffix
		
		
		
		// Keep the memory useage low
		if (poolCount > 10) {
			[innerPool drain];
			poolCount = 0;
		} else {
			poolCount += 1;
		}
	}
	
	#pragma mark Wait for the user to log out
	NSLog_notice(@"Waiting for User Logout");
	if (testingMode) {
		NSLog_notice(@"	Testing: waiting 5 seconds");
		sleep(5);
	} else {
		#pragma mark - TODO: wait for the user log out
	}
	
	#pragma mark Remove selected files
	
	#pragma mark - shift ByHost files
	if (byHostImageName != nil) {
		NSLog_notice(@"Moving aside ByHost items");
		NSString * byHostPath = [homeDirectory stringByAppendingPathComponent:@"Library/Preferences/ByHost"];
		BOOL isFolder;
		if ([fileManager fileExistsAtPath:byHostPath isDirectory:&isFolder] == TRUE && isFolder == TRUE) {
			for (NSString * directoryItem in [fileManager directoryContentsAtPath:byHostPath]) {
				if ([directoryItem rangeOfString:byHostIDString].location != NSNotFound) {
					NSLog_debug(@"	Moving aside ByHost item: %@", directoryItem);
					
					NSString * sourcePath = [byHostPath stringByAppendingPathComponent:directoryItem];
					NSString * targetPath = [byHostPath stringByAppendingPathComponent:[directoryItem stringByReplacingOccurrencesOfString:byHostIDString withString:byHostImageName]];
					
					NSError * myError;
					
					if ([fileManager fileExistsAtPath:targetPath isDirectory:&isFolder] == TRUE) {
						if (isFolder) {
							NSLog_warn(@"	Unable to move ByHost item aside because a folder is at the location: %@", directoryItem);
							continue;
						} else {
							if ([fileManager removeItemAtPath:targetPath error:&myError] == FALSE) {
								NSLog_warn(@"	Unable to remove the item at %@", targetPath);
								continue;
							}
						}
					}
					
					if ([fileManager moveItemAtPath:sourcePath toPath:targetPath error:&myError] == TRUE) {
						NSLog_debug(@"		Moved ByHost item to: %@", targetPath);
					} else {
						NSLog_warn(@"	Failed to move aside ByHost item: %@", directoryItem);
					}

				}
			}
		}
	}
	
    [pool drain];
    return 0;
}
 