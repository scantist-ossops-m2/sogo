/* MAPIStoreCalendarMessage.m - this file is part of SOGo
 *
 * Copyright (C) 2011 Inverse inc
 *
 * Author: Wolfgang Sourdeau <wsourdeau@inverse.ca>
 *
 * This file is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2, or (at your option)
 * any later version.
 *
 * This file is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; see the file COPYING.  If not, write to
 * the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
 * Boston, MA 02111-1307, USA.
 */

/* TODO:
   - merge common code with tasks
   - take the tz definitions from Outlook */

#import <Foundation/NSArray.h>
#import <Foundation/NSData.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSString.h>
#import <Foundation/NSTimeZone.h>
#import <NGObjWeb/WOContext+SoObjects.h>
#import <NGExtensions/NSObject+Logs.h>
#import <NGCards/iCalDateTime.h>
#import <NGCards/iCalEvent.h>
#import <NGCards/iCalRecurrenceRule.h>
#import <NGCards/iCalTimeZone.h>
#import <NGCards/iCalPerson.h>
#import <SOGo/SOGoUser.h>
#import <SOGo/SOGoUserDefaults.h>
#import <Appointments/SOGoAppointmentObject.h>

#import "MAPIStoreAttachmentTable.h"
#import "MAPIStoreCalendarAttachment.h"
#import "MAPIStoreContext.h"
#import "MAPIStoreRecurrenceUtils.h"
#import "MAPIStoreTypes.h"
#import "NSCalendarDate+MAPIStore.h"
#import "NSData+MAPIStore.h"
#import "NSString+MAPIStore.h"
#import "NSValue+MAPIStore.h"

#import "MAPIStoreCalendarMessage.h"

#undef DEBUG
#include <stdbool.h>
#include <gen_ndr/exchange.h>
#include <gen_ndr/property.h>
#include <libmapi/libmapi.h>
#include <mapistore/mapistore.h>
#include <mapistore/mapistore_errors.h>
#include <mapistore/mapistore_nameid.h>

// extern void ndr_print_AppointmentRecurrencePattern(struct ndr_print *ndr, const char *name, const struct AppointmentRecurrencePattern *r);

static NSTimeZone *utcTZ;

@implementation MAPIStoreCalendarMessage

+ (void) initialize
{
  utcTZ = [NSTimeZone timeZoneWithName: @"UTC"];
  [utcTZ retain];
}

- (id) init
{
  if ((self = [super init]))
    {
      attachmentKeys = [NSMutableArray new];
      attachmentParts = [NSMutableDictionary new];
    }

  return self;
}

- (NSTimeZone *) ownerTimeZone
{
  NSString *owner;
  SOGoUserDefaults *ud;
  NSTimeZone *tz;
  WOContext *woContext;

  woContext = [[self context] woContext];
  owner = [sogoObject ownerInContext: woContext];
  ud = [[SOGoUser userWithLogin: owner] userDefaults];
  tz = [ud timeZone];

  return tz;
}

- (void) _setupRecurrenceInCalendar: (iCalCalendar *) calendar
                    withMasterEvent: (iCalEvent *) vEvent
                           fromData: (NSData *) mapiRecurrenceData
{
  struct Binary_r *blob;
  struct AppointmentRecurrencePattern *pattern;
  NSMutableArray *otherEvents;

  /* cleanup */
  otherEvents = [[calendar events] mutableCopy];
  [otherEvents removeObject: vEvent];
  [calendar removeChildren: otherEvents];
  [otherEvents release];

  blob = [mapiRecurrenceData asBinaryInMemCtx: memCtx];
  pattern = get_AppointmentRecurrencePattern (memCtx, blob);
  [calendar setupRecurrenceWithMasterEntity: vEvent
                      fromRecurrencePattern: &pattern->RecurrencePattern];
  talloc_free (pattern);
  talloc_free (blob);
}

static void
_fillAppointmentRecurrencePattern (struct AppointmentRecurrencePattern *arp,
                                   NSCalendarDate *startDate, NSTimeInterval duration,
                                   NSCalendarDate * endDate, iCalRecurrenceRule * rule)
{
  uint32_t startMinutes;

  [rule fillRecurrencePattern: &arp->RecurrencePattern
                withStartDate: startDate andEndDate: endDate];
  arp->ReaderVersion2 = 0x00003006;
  arp->WriterVersion2 = 0x00003009;

  startMinutes = ([startDate hourOfDay] * 60 + [startDate minuteOfHour]);
  arp->StartTimeOffset = startMinutes;
  arp->EndTimeOffset = startMinutes + (uint32_t) (duration / 60);

  arp->ExceptionCount = 0;
  arp->ReservedBlock1Size = 0;

  /* Currently ignored in property.idl: 
     arp->ReservedBlock2Size = 0; */
}

- (struct SBinary_short *) _computeAppointmentRecur
{
  struct AppointmentRecurrencePattern *arp;
  struct Binary_r *bin;
  struct SBinary_short *sBin;
  NSCalendarDate *firstStartDate;
  iCalEvent *vEvent;
  iCalRecurrenceRule *rule;

  vEvent = [sogoObject component: NO secure: NO];
  rule = [[vEvent recurrenceRules] objectAtIndex: 0];

  firstStartDate = [vEvent firstRecurrenceStartDate];
  if (firstStartDate)
    {
      [firstStartDate setTimeZone: [self ownerTimeZone]];

      arp = talloc_zero (memCtx, struct AppointmentRecurrencePattern);
      _fillAppointmentRecurrencePattern (arp, firstStartDate,
                                         [vEvent durationAsTimeInterval],
                                         [vEvent lastPossibleRecurrenceStartDate],
                                         rule);
      sBin = talloc_zero (memCtx, struct SBinary_short);
      bin = set_AppointmentRecurrencePattern (sBin, arp);
      sBin->cb = bin->cb;
      sBin->lpb = bin->lpb;
      talloc_free (arp);

      // DEBUG(5, ("To client:\n"));
      // NDR_PRINT_DEBUG (AppointmentRecurrencePattern, arp);
    }
  else
    {
      [self errorWithFormat: @"no first occurrence found in rule: %@", rule];
      sBin = NULL;
    }

  return sBin;
}

- (enum MAPISTATUS) getProperty: (void **) data
                        withTag: (enum MAPITAGS) propTag
{
  NSTimeInterval timeValue;
  id event;
  uint32_t longValue;
  int rc;

  rc = MAPI_E_SUCCESS;
  switch ((uint32_t) propTag)
    {
    case PR_ICON_INDEX: // TODO
      /* see http://msdn.microsoft.com/en-us/library/cc815472.aspx */
      // *longValue = 0x00000401 for recurring event
      // *longValue = 0x00000402 for meeting
      // *longValue = 0x00000403 for recurring meeting
      // *longValue = 0x00000404 for invitation

      event = [sogoObject component: NO secure: NO];
      longValue = 0x0400;
      if ([event isRecurrent])
        longValue |= 0x0001;
      if ([[event attendees] count] > 0)
        longValue |= 0x0002;

      *data = MAPILongValue (memCtx, longValue);
      break;
    case PR_MESSAGE_CLASS_UNICODE:
      *data = talloc_strdup(memCtx, "IPM.Appointment");
      break;
    case PidLidAppointmentDuration:
      event = [sogoObject component: NO secure: NO];
      timeValue = [[event endDate] timeIntervalSinceDate: [event startDate]];
      *data = MAPILongValue (memCtx, (uint32_t) (timeValue / 60));
      break;
    case PidLidAppointmentSubType:
      event = [sogoObject component: NO secure: NO];
      *data = MAPIBoolValue (memCtx, [event isAllDay]);
      break;
    case PidLidBusyStatus: // TODO
      *data = MAPILongValue (memCtx, 0x02);
      break;

    // case 0x82410003: // TODO
    //   *data = MAPILongValue (memCtx, 0);
    //   break;
    case PR_SUBJECT_UNICODE: // SUMMARY
      event = [sogoObject component: NO secure: NO];
      *data = [[event summary] asUnicodeInMemCtx: memCtx];
      break;
    case PidLidLocation: // LOCATION
      event = [sogoObject component: NO secure: NO];
      *data = [[event location] asUnicodeInMemCtx: memCtx];
      break;
    case PidLidPrivate: // private (bool), should depend on CLASS and permissions
      *data = MAPIBoolValue (memCtx, NO);
      break;
    case PR_SENSITIVITY: // not implemented, depends on CLASS
      // normal = 0, personal?? = 1, private = 2, confidential = 3
      *data = MAPILongValue (memCtx, 0);
      break;
    case PR_CREATION_TIME:
      event = [sogoObject component: NO secure: NO];
      *data = [[event created] asFileTimeInMemCtx: memCtx];
      break;

    case PR_IMPORTANCE:
      {
	unsigned int v;

	event = [sogoObject component: NO secure: NO];

	if ([[event priority] isEqualToString: @"9"])
	  v = 0x0;
	else if ([[event priority] isEqualToString: @"1"])
	  v = 0x2;
	else
	  v = 0x1;

	*data = MAPILongValue (memCtx, v);
      }
      break;


      /* Recurrence */
    case PidLidIsRecurring:
    case PidLidRecurring:
      event = [sogoObject component: NO secure: NO];
      *data = MAPIBoolValue (memCtx, [event isRecurrent]);
      break;
    case PidLidAppointmentRecur:
      event = [sogoObject component: NO secure: NO];
      if ([event isRecurrent])
        *data = [self _computeAppointmentRecur];
      else
        rc = MAPISTORE_ERR_NOT_FOUND;
      break;

      // case PidLidTimeZoneStruct:
      // case PR_VD_NAME_UNICODE:
      //         *data = talloc_strdup(memCtx, "PR_VD_NAME_UNICODE");
      //         break;
      // case PR_EMS_AB_DXA_REMOTE_CLIENT_UNICODE: "Home:" ???
      //         *data = talloc_strdup(memCtx, "PR_EMS...");
      //         break;
    default:
      rc = [super getProperty: data
                      withTag: propTag];
    }

  // #define PR_REPLY_TIME                                       PROP_TAG(PT_SYSTIME   , 0x0030) /* 0x00300040 */
  // #define PR_INTERNET_MESSAGE_ID_UNICODE                      PROP_TAG(PT_UNICODE   , 0x1035) /* 0x1035001f */
  // #define PR_FLAG_STATUS                                      PROP_TAG(PT_LONG      , 0x1090) /* 0x10900003 */

  return rc;
}

- (void) openMessage: (struct mapistore_message *) msg
{
  NSString *name, *email;
  NSArray *attendees;
  iCalPerson *person;
  id event;
  struct SRowSet *recipients;
  int count, max;

  [super openMessage: msg];
  event = [sogoObject component: NO secure: NO];
  attendees = [event attendees];
  max = [attendees count];

  recipients = msg->recipients;
  recipients->cRows = max;
  recipients->aRow = talloc_array (recipients, struct SRow, max);
  
  for (count = 0; count < max; count++)
    {
      recipients->aRow[count].ulAdrEntryPad = 0;
      recipients->aRow[count].cValues = 3;
      recipients->aRow[count].lpProps = talloc_array (recipients->aRow,
                                                      struct SPropValue,
                                                      3);
      
      // TODO (0x01 = primary recipient)
      set_SPropValue_proptag (&(recipients->aRow[count].lpProps[0]),
                              PR_RECIPIENT_TYPE,
                              MAPILongValue (memCtx, 0x01));
      
      person = [attendees objectAtIndex: count];
      
      name = [person cn];
      if (!name)
        name = @"";
	  
      email = [person email];
      if (!email)
        email = @"";
	  
      set_SPropValue_proptag (&(recipients->aRow[count].lpProps[1]),
                              PR_DISPLAY_NAME,
                              [name asUnicodeInMemCtx: recipients->aRow[count].lpProps]);
      set_SPropValue_proptag (&(recipients->aRow[count].lpProps[2]),
                              PR_EMAIL_ADDRESS,
                              [email asUnicodeInMemCtx: recipients->aRow[count].lpProps]);
    }
}

- (void) save
{
  WOContext *woContext;
  iCalCalendar *vCalendar;
  iCalEvent *vEvent;
  iCalDateTime *start, *end;
  iCalTimeZone *tz;
  NSCalendarDate *now;
  NSString *content, *tzName;
  id value;

  [self logWithFormat: @"-save, event props:"];
  // MAPIStoreDumpMessageProperties (newProperties);

  content = [sogoObject contentAsString];
  if (![content length])
    {
      vEvent = [sogoObject component: YES secure: NO];
      vCalendar = [vEvent parent];
      [vCalendar setProdID: @"-//Inverse inc.//OpenChange+SOGo//EN"];
      content = [vCalendar versitString];
    }

  vCalendar = [iCalCalendar parseSingleFromSource: content];
  vEvent = [[vCalendar events] objectAtIndex: 0];

  // summary
  value = [newProperties
            objectForKey: MAPIPropertyKey (PR_NORMALIZED_SUBJECT_UNICODE)];
  if (value)
    [vEvent setSummary: value];

  // Location
  value = [newProperties objectForKey: MAPIPropertyKey (PidLidLocation)];
  if (value)
    [vEvent setLocation: value];

  tzName = [[self ownerTimeZone] name];
  tz = [iCalTimeZone timeZoneForName: tzName];
  [vCalendar addTimeZone: tz];

  // start
  value = [newProperties objectForKey: MAPIPropertyKey (PR_START_DATE)];
  if (!value)
    value = [newProperties objectForKey: MAPIPropertyKey (PidLidAppointmentStartWhole)];
  if (value)
    {
      start = (iCalDateTime *) [vEvent uniqueChildWithTag: @"dtstart"];
      [start setTimeZone: tz];
      [start setDateTime: value];
    }

  // end
  value = [newProperties objectForKey: MAPIPropertyKey (PR_END_DATE)];
  if (!value)
    value = [newProperties objectForKey: MAPIPropertyKey (PidLidAppointmentEndWhole)];
  if (value)
    {
      end = (iCalDateTime *) [vEvent uniqueChildWithTag: @"dtend"];
      [end setTimeZone: tz];
      [end setDateTime: value];
    }

  now = [NSCalendarDate date];
  if ([sogoObject isNew])
    {
      [vEvent setCreated: now];
    }
  [vEvent setTimeStampAsDate: now];

  // Organizer and attendees
  value = [newProperties objectForKey: @"recipients"];

  if (value)
    {
      NSArray *recipients;
      NSDictionary *dict;
      iCalPerson *person;
      int i;

      woContext = [[self context] woContext];
      dict = [[woContext activeUser] primaryIdentity];
      person = [iCalPerson new];
      [person setCn: [dict objectForKey: @"fullName"]];
      [person setEmail: [dict objectForKey: @"email"]];
      [vEvent setOrganizer: person];
      [person release];

      recipients = [value objectForKey: @"to"];
      
      for (i = 0; i < [recipients count]; i++)
	{
	  dict = [recipients objectAtIndex: i];
	  person = [iCalPerson new];

	  [person setCn: [dict objectForKey: @"fullName"]];
	  [person setEmail: [dict objectForKey: @"email"]];
	  [person setParticipationStatus: iCalPersonPartStatNeedsAction];
	  [person setRsvp: @"TRUE"];
	  [person setRole: @"REQ-PARTICIPANT"]; 

	  // FIXME: We must NOT always rely on this
	  if (![vEvent isAttendee: [person rfc822Email]])
	    [vEvent addToAttendees: person];

	  [person release];
	}
    }

  /* recurrence */
  value = [newProperties
            objectForKey: MAPIPropertyKey (PidLidAppointmentRecur)];
  if (value)
    [self _setupRecurrenceInCalendar: vCalendar
                     withMasterEvent: vEvent
                            fromData: value];

  // [sogoObject saveContentString: [vCalendar versitString]];
  [sogoObject saveComponent: vEvent];
}

/* TODO: those are stubs meant to prevent OpenChange from crashing when a
   recurring event is open */
- (NSArray *) childKeysMatchingQualifier: (EOQualifier *) qualifier
                        andSortOrderings: (NSArray *) sortOrderings
{
  /* TODO: Here we should return recurrence exceptions */
  return attachmentKeys;
}

- (id) lookupChild: (NSString *) childKey
{
  return [attachmentParts objectForKey: childKey];
}

- (MAPIStoreAttachmentTable *) attachmentTable
{
  return [MAPIStoreAttachmentTable tableForContainer: self];
}

- (MAPIStoreAttachment *) createAttachment
{
  MAPIStoreCalendarAttachment *newAttachment;
  uint32_t newAid;
  NSString *newKey;

  newAid = [attachmentKeys count];

  newAttachment = [MAPIStoreCalendarAttachment
                    mapiStoreObjectWithSOGoObject: nil
                                      inContainer: self];
  [newAttachment setIsNew: YES];
  [newAttachment setAID: newAid];
  newKey = [NSString stringWithFormat: @"%ul", newAid];
  [attachmentParts setObject: newAttachment
                      forKey: newKey];
  [attachmentKeys addObject: newKey];

  return newAttachment;
}

@end
