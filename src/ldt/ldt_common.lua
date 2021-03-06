-- Large Data Type (LDT) Common Functions
-- ======================================================================
-- Copyright [2014] Aerospike, Inc.. Portions may be licensed
-- to Aerospike, Inc. under one or more contributor license agreements.
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--  http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
-- ======================================================================
--
-- Track the data and iteration of the last update.
local MOD="ldt_common_2014_06_30.D";

-- This variable holds the version of the code.  It would be in the form
-- of (Major.Minor), except that Lua does not store real numbers.  So, for
-- now, our version is just a simple integer.
-- We'll check this for Major design changes -- and try to maintain some
-- amount of inter-version compatibility.
local G_LDT_VERSION = 2;

-- ======================================================================
-- || GLOBAL PRINT and GLOBAL DEBUG ||
-- ======================================================================
-- Use these flags to enable/disable global printing (the "detail" level
-- in the server).
-- Usage: GP=F and trace()
-- When "F" is true, the trace() call is executed.  When it is false,
-- the trace() call is NOT executed (regardless of the value of GP)
-- (*) "F" is used for general debug prints
-- (*) "E" is used for ENTER/EXIT prints
-- (*) "B" is used for BANNER prints
-- (*) DEBUG is used for larger structure content dumps.
-- ======================================================================
local GP;      -- Global Print Instrument
local F=false; -- Set F (flag) to true to turn ON global print
local E=false; -- Set E (ENTER/EXIT) to true to turn ON Enter/Exit print
local B=false; -- Set B (Banners) to true to turn ON Banner Print
local D=false; -- Set D (Detail) to true to turn (verbose) Details Prints
local GD;     -- Global Debug instrument.
local DEBUG=false; -- turn on for more elaborate state dumps.

-- Turn this ON to see mid-flight sub-rec updates called, and OFF to leave
-- the updates to the end -- at the close of Lua.
-- Currently this must be turned ON in order to bypass a bug in the sub-Rec
-- support code.
local DO_EARLY_SUBREC_UPDATES=true;

-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- <<  LDT COMMON Functions >>
-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- The following functions were moved into common for two main reasons:
-- (1) Mandatory: All of the LDT routines must use the following
--     functions in the same way with the same function:
--     + Sub-Rec Context Functions
--     + Key, Read, Write Functions (those using inner UDFs)
--     + Propery Map Management
-- (2) Convenience: We know that many of the LDT routines need some common
--     support for Lists (search, insert, delete, summarize) and Common 
--     Object summary.  This Convenience list may grow over time.
-- =====================================================================
-- GLOBAL FUNCTIONS (key, filter, transform, untransform)
-- ldt_common.setKeyFunction( ldtMap, required, currentFunctionPtr )
-- ldt_common.setReadFunctions( ldtMap, userModule, filter, filterArgs )
-- ldt_common.setWriteFunctions( ldtMap )
--
-- SUB-RECORD CONTEXT FUNCTIONS
-- ldt_common.createSubRecContext()
-- ldt_common.createSubRec( srcCtrl, topRec, ldtCtrl, recType )
-- ldt_common.closeSubRec( srcCtrl, digestString )
-- ldt_common.createAndInitESR(srcCtrl, topRec, ldtCtrl )
-- ldt_common.updateSubRec( srcCtrl, subRec )
-- ldt_common.markSubRecDirty( srcCtrl, digestString )
-- ldt_common.closeAllSubRecs( srcCtrl )
-- ldt_common.removeSubRec( srcCtrl, digestString )
--
-- ldt_common.setLdtRecordType( topRec )
-- ldt_common.ldtInitPropMap( propMap, esrDigest, selfDigest, topDigest,
-- ldt_common.adjustLdtMap( ldtCtrl, argListMap, ldtSpecificPackage)
--
-- UTILITY FUNCTIONS (dump, summarize, etc)
-- ldt_common.propMapSummary( resultMap, propMap )
-- ldt_common.summarizeList( myList )
-- ldt_common.dumpList( myList )
-- ldt_common.summarizeMap( myMap )
-- ldt_common.dumpMap( myMap )
--
-- VALIDATION FUNCTIONS
-- ldt_common.validateBinName( ldtBinName )
-- ldt_common.validateRecBinAndMap( topRec, ldtBinName, mustExist )
--
-- LIST FUNCTIONS
-- ldt_common.listAppendList( baseList, additionalList )
-- ldt_common.listInsert( valList, newValue, position )
-- ldt_common.listDelete( objectList, position )
-- ldt_common.validateList( valList )
--
-- OBJECT FUNCTIONS
-- ldt_common.createPersonObject( flavor, skew )

-- ======================================================================
-- Using These Functions:
-- ======================================================================
-- We use this map to export the externally visible functions from
-- LDT_COMMON.  The LDT External Modules will include this common module
-- with a "require" command, like this:
-- ==>   local ldt_common = require('ldt/ldt_common');
-- Then it will perform calls on these common functions as if they were
-- components of a map or table:
-- ==>   ldt_common.setLdtRecordType( topRec );
-- ======================================================================
local ldt_common = {};
-- ======================================================================

-- ======================================================================
-- Aerospike Server Functions:
-- ======================================================================
-- These functions represent crossover from the Aerospike Database World
-- to the Lua World.  These functions perform Aerospike operations on
-- either main records or sub-records (or both).
-- ======================================================================
-- Aerospike Main Record Functions:
-- status = aerospike:create( topRec )
-- status = aerospike:update( topRec )
-- status = aerospike:remove( rec ) (not currently used)
--
-- Aerospike SubRecord Functions:
-- newRec = aerospike:create_subrec( topRec )
-- rec    = aerospike:open_subrec( topRec, childRecDigest)
-- status = aerospike:update_subrec( childRec )
-- status = aerospike:close_subrec( childRec )
-- status = aerospike:remove_subrec( subRec )  
--
-- Record Functions:
-- digest = record.digest( childRec )
-- status = record.set_type( topRec, recType )
-- status = record.set_flags( topRec, ldtBinName, binFlags )
-- ======================================================================

-- ++==================++
-- || External Modules ||
-- ++==================++
-- Get addressability to the Function Table: Used for compress and filter
local functionTable = require('ldt/UdfFunctionTable');

-- Common LDT functions that are used by ALL of the LDTs.
-- local LDTC = require('ldt/ldt_common');
local ldte=require('ldt/ldt_errors');

-- ++==================++
-- || GLOBAL CONSTANTS || -- Local, but global to this module
-- ++==================++
local MAGIC="MAGIC";     -- the magic value for Testing LSTACK integrity

-- AS_BOOLEAN TYPE:
-- There are apparently either storage or conversion problems with booleans
-- and Lua and Aerospike, so rather than STORE a Lua Boolean value in the
-- LDT Control map, we're instead going to store an AS_BOOLEAN value, which
-- is a character (defined here).  We're using Characters rather than
-- numbers (0, 1) because a character takes ONE byte and a number takes EIGHT
local AS_TRUE='T';    
local AS_FALSE='F';

-- Record Types -- Must be numbers, even though we are eventually passing
-- in just a "char" (and int8_t).
-- NOTE: We are using these vars for TWO purposes -- and I hope that doesn't
-- come back to bite me.
-- (1) As a flag in record.set_type() -- where the index bits need to show
--     the TYPE of record (CDIR NOT used in this context)
-- (2) As a TYPE in our own propMap[PM_RecType] field: CDIR *IS* used here.
local RT_REG = 0; -- 0x0: Regular Record (Here only for completeneness)
local RT_LDT = 1; -- 0x1: Top Record (contains an LDT)
local RT_SUB = 2; -- 0x2: Regular Sub Record (Anything other than ESR)
local RT_ESR = 4; -- 0x4: Existence Sub Record

-- Bin Flag Types -- to show the various types of bins.
-- NOTE: All bins will be labelled as either (1:RESTRICTED OR 2:HIDDEN)
-- We will not currently be using "Control" -- that is effectively HIDDEN
local BF_LDT_BIN     = 1; -- Main LDT Bin (Restricted)
local BF_LDT_HIDDEN  = 2; -- LDT Bin::Set the Hidden Flag on this bin
local BF_LDT_CONTROL = 4; -- Main LDT Control Bin (one per record)

-- Our Dirty Map has two settings:  Dirty and Busy.
-- Dirty means that it has been written, and thus cannot be closed.
-- Busy means that it is read-only, but currently in use and cannot be closed.
local DM_DIRTY = 'D';
local DM_BUSY  = 'B';

-- We maintain a pool, or "context", of sub-records that are open.  That allows
-- us to look up subRecs and get the open reference, rather than bothering
-- the lower level infrastructure.  There's also a limit to the number
-- of open subRecs.
local G_OPEN_SR_LIMIT = 20;

-- When the user wants to override the default settings, or register some
-- functions, the user module with the "adjust_settings" function will be
-- used.
local G_SETTINGS = "adjust_settings";

-- ++====================++
-- || INTERNAL BIN NAMES || -- Local, but global to this module
-- ++====================++
-- The Top Rec LDT bin is named by the user -- so there's no hardcoded name
-- for each used LDT bin.
--
-- In the main record, there is one special hardcoded bin -- that holds
-- some shared information for all LDTs.
-- Note the 14 character limit on Aerospike Bin Names.
-- >> (14 char name limit) 12345678901234 <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
local REC_LDT_CTRL_BIN  = "LDTCONTROLBIN"; -- Single bin for all LDT in rec

-- All LDT subRecords have a properties bin that holds a map that defines
-- the specifics of the record and the LDT.
-- NOTE: Even the TopRec has a property map -- but it's stashed in the
-- user-named LDT Bin
-- >> (14 char name limit) 12345678901234 <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
local SUBREC_PROP_BIN   = "SR_PROP_BIN";

-- Each LDT Flavor (stack, list, map, set) has its own SubRec bins
-- that are specific to the needs of the type.  They are not common.
--
-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- <><><><> <Initialize Control Maps> <Initialize Control Maps> <><><><>
-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- There are four main Record Types used in the LSTACK Package, and their
-- initialization functions follow.  The initialization functions
-- define the "type" of the control structure:
--
-- (*) TopRec: the top level user record that contains the LSTACK bin
-- (*) EsrRec: The Existence SubRecord (ESR) that coordinates all child
--             subRecs for a given LDT.
-- (*) LdrRec: the LDT Data Record (LDR) that holds user Data.
-- (*) ColdDirRec: The Record that holds a list of Sub Record Digests
--     (i.e. record pointers) to the LDR Data Records.  The Cold list is
--     a linked list of Directory pages;  each dir contains a list of
--     digests (record pointers) to the LDR data pages.
-- <+> Naming Conventions:
--   + All Field names (e.g. ldtMap[StoreMode]) begin with Upper Case
--   + All variable names (e.g. ldtMap[StoreMode]) begin with lower Case
--   + As discussed below, all Map KeyField names are INDIRECTLY referenced
--     via descriptive variables that map to a single character (to save
--     space when the entire map is msg-packed into a record bin).
--   + All Record Field access is done using brackets, with either a
--     variable or a constant (in single quotes).
--     (e.g. topRec[ldtBinName] or ldrRec[LDR_CTRL_BIN]);
--
-- <+> Recent Change in LdtMap Use: (6/21/2013 tjl)
--   + In order to maintain a common access mechanism to all LDTs, AND to
--     limit the amount of data that must be "un-msg-packed" when accessed,
--     we will use a common property map and a type-specific property map.
--     That means that the "ldtMap" that was the primary value in the LdtBin
--     is now a list, where ldtCtrl[1] will always be the propMap and
--     ldtCtrl[2] will always be the ldtMap.  In the server code, using "C",
--     we will sometimes read the ldtCtrl[1] (the property map) in order to
--     perform some LDT management operations.
--   + Since Lua wraps up the LDT Control map as a self-contained object,
--     we are paying for storage in EACH LDT Bin for the map field names. 
--     Thus, even though we like long map field names for readability:
--     e.g.  ldtMap.HotEntryListItemCount, we don't want to spend the
--     space to store the large names in each and every LDT control map.
--     So -- we do another Lua Trick.  Rather than name the key of the
--     map value with a large name, we instead use a single character to
--     be the key value, but define a descriptive variable name to that
--     single character.  So, instead of using this in the code:
--     ldtMap.HotEntryListItemCount = 50;
--            123456789012345678901
--     (which would require 21 bytes of storage); We instead do this:
--     local HotEntryListItemCount='H';
--     ldtMap[HotEntryListItemCount] = 50;
--     Now, we're paying the storage cost for 'H' (1 byte) and the value.
--
--     So -- we have converted all of our LDT lua code to follow this
--     convention (fields become variables the reference a single char)
--     and the mapping of long name to single char will be done in the code.
-- ------------------------------------------------------------------------
-- ------------------------------------------------------------------------
-- Control Map Names: for Property Maps and Control Maps
-- ------------------------------------------------------------------------
-- Note:  All variables that are field names will be upper case.
-- It is EXTREMELY IMPORTANT that these field names ALL have unique char
-- values -- within any given map.  They do NOT have to be unique across
-- the maps (and there's no need -- they serve different purposes).
-- Note that we've tried to make the mapping somewhat cannonical where
-- possible. 
-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
-- Record Level Property Map (RPM) Fields: One RPM per record
-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
local RPM_LdtCount             = 'C';  -- Number of LDTs in this rec
local RPM_VInfo                = 'V';  -- Partition Version Info
local RPM_Magic                = 'Z';  -- Special Sauce
local RPM_SelfDigest           = 'D';  -- Digest of this record
-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
-- LDT specific Property Map (PM) Fields: One PM per LDT bin:
-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
local PM_ItemCount             = 'I'; -- (Top): # of items in LDT
local PM_SubRecCount           = 'S'; -- (Top): # of subRecs in the LDT
local PM_Version               = 'V'; -- (Top): Code Version
local PM_LdtType               = 'T'; -- (Top): Type: stack, set, map, list
local PM_BinName               = 'B'; -- (Top): LDT Bin Name
local PM_Magic                 = 'Z'; -- (All): Special Sauce
local PM_CreateTime            = 'C'; -- (All): Creation time of this rec
local PM_EsrDigest             = 'E'; -- (All): Digest of ESR
local PM_RecType               = 'R'; -- (All): Type of Rec:Top,Ldr,Esr,CDir
-- local PM_LogInfo               = 'L'; -- (All): Log Info (currently unused)
local PM_ParentDigest          = 'P'; -- (SubRec): Digest of TopRec
local PM_SelfDigest            = 'D'; -- (SubRec): Digest of THIS Record

-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
-- LDT Map Fields Common to ALL LDTs (managed by the LDT COMMON routines)
-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
local M_UserModule          = 'P';-- User's Lua file for overrides
local M_KeyFunction         = 'F';-- Function to compute Key from Object
local M_KeyType             = 'k'; -- Key Type: Atomic or Complex
local M_StoreMode           = 'M';-- SM_LIST or SM_BINARY (applies to all nodes)
local M_StoreLimit          = 'L';-- Storage Capacity Limit
local M_Transform           = 't';-- Transform Object (from User to bin store)
local M_UnTransform         = 'u';-- Reverse transform (from storage to user)
--
-- ======================================================================
-- <USER FUNCTIONS> - <USER FUNCTIONS> - <USER FUNCTIONS> - <USER FUNCTIONS>
-- ======================================================================
-- We have several different situations where we need to look up a user
-- defined function:
-- (*) Object Transformation (e.g. compression)
-- (*) Object UnTransformation
-- (*) Predicate Filter (perform additional predicate tests on an object)
--
-- These functions are passed in by name (UDF name, Module Name), so we
-- must check the existence/validity of the module and UDF each time we
-- want to use them.  Furthermore, we want to centralize the UDF checking
-- into one place -- so on entry to those LDT functions that might employ
-- these UDFs (e.g. insert, filter), we'll set up either READ UDFs or
-- WRITE UDFs and then the inner routines can call them if they are
-- non-nil.
-- ======================================================================
-- These values cannot be global to this module -- they must be passed in
-- from the outer LDT Library functions.
-- =======================
-- local G_Filter = nil;
-- local G_Transform = nil;
-- local G_UnTransform = nil;
-- local G_FunctionArgs = nil;
-- local G_KeyFunction = nil;

-- <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> 
-- -----------------------------------------------------------------------
-- resetPtrs()
-- -----------------------------------------------------------------------
-- Reset the UDF Ptrs to nil.
-- NOTE that this function must stay in the outer LDT Library Modules.
-- -----------------------------------------------------------------------
-- local function resetUdfPtrs()
--   G_Filter = nil;
--   G_Transform = nil;
--   G_UnTransform = nil;
--   G_FunctionArgs = nil;
--   G_KeyFunction = nil;
-- end -- resetPtrs()

-- <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> 
-- -----------------------------------------------------------------------
-- setKeyFunction()
-- -----------------------------------------------------------------------
-- The function that extracts a key value from a complex object can
-- be in the user's "creation" module, or it can be in the FunctionTable.
-- The "Key" Function may be slightly misleading, depending on the LDT
-- that is being used.
-- (*) LSET: The KeyFunction extracts a unique subset from a complex object
--           that can be compared (equals only). For LSET, a KeyFunction is
--           not required, as a complex object can always be converted to a
--           string for an equals compare.
-- (*) LMAP: The KeyFunction is not used, since values are found with "name",
--           which must be an atomic (number or string) value.
-- (*) LLIST: The KeyFunction extracts an atomic value from a complex object
--            that can be ordered.  For LLIST, if the object being stored is
--            complex, then it is REQUIRED that there is a valid KeyFunction
--            to extract an atomic value that can be compared and ordered.
--            The type of the FIRST INSERT determines the type of the LLIST.
-- (*) LSTACK: For regular LSTACK, there is no need for a KeyFunction.
--            However, for TIMESTACK, a special flavor of LSTACK, the 
--            KeyFunction extracts a TIME value from the object, which must
--            be a number that can be used in an ordered compare.
-- Parms:
-- (*) ldtMap: The basic control info
-- (*) required: True when we must have a valid KeyFunction, e.g. LLIST.
-- (*) currentFunctionPtr: The caller's existing Key Function Ptr.  We bother
--     with this work ONLY if the existing Key Function Ptr is empty.
-- Results:
-- OK: Return located KeyFunctionPtr
-- ERROR: 
-- -----------------------------------------------------------------------
function ldt_common.setKeyFunction( ldtMap, required, currentFunctionPtr )
  local meth = "setKeyFunction()";
  GP=E and trace("[ENTER]<%s:%s> Required(%s) CurFP(%s)", MOD, meth,
    tostring(required), tostring(currentFunctionPtr));

  -- If there is ALREADY a non-NULL Key Function Ptr (passed in by the
  -- caller who apparently forgot to check), then just give that ptr
  -- back to her.  Careful coding suggests that this should not happen.
  if( currentFunctionPtr ~= nil ) then
      return currentFunctionPtr;
  end

  local createModuleRef; -- Hold the imported module table

  -- Look in the Create Module first, then check the Function Table.
  -- The Name of the key function is stored in the ldtMap -- get that name
  -- and then look for where it is located.
  local createModule = ldtMap[M_UserModule];
  local keyFunctionName = ldtMap[M_KeyFunction];
  local keyFunctionPtr = nil;
  if( keyFunctionName ~= nil ) then
    if( type(keyFunctionName) ~= "string" or keyFunctionName == "" ) then
      warn("[ERROR]<%s:%s> Bad KeyFunction Name: type(%s) KeyFunction(%s)",
        MOD, meth, type(keyFunctionName), tostring(keyFunctionName) );
      error( ldte.ERR_KEY_FUN_BAD );
    else
      -- Ok -- so far, looks like we have a valid key function name, 
      -- Look in the Create Module, and if that's not found, then look
      -- in the system function table.
      if( createModule ~= nil ) then
        createModuleRef = require(createModule);
        if(createModuleRef ~= nil and createModuleRef[keyFunctionName] ~= nil)
        then
          keyFunctionPtr = createModuleRef[keyFunctionName];
        end
      end

      -- Last we try the UdfFunctionTable, In case the user wants to employ
      -- one of the standard Key Functions.
      if( keyFunctionPtr == nil and functionTable ~= nil ) then
        keyFunctionPtr = functionTable[keyFunctionName];
      end

      -- If we didn't find anything, BUT the user supplied a function name,
      -- then we have a problem.  We have to complain.
      if( keyFunctionPtr == nil ) then
        warn("[ERROR]<%s:%s> KeyFunction not found: type(%s) KeyFunction(%s)",
          MOD, meth, type(keyFunctionName), tostring(keyFunctionName) );
        error( ldte.ERR_KEY_FUN_NOT_FOUND );
      end
    end
  elseif( ldtMap[M_KeyType] == KT_COMPLEX and required == true ) then
    warn("[ERROR]<%s:%s> Key Function is Required for this LDT Complex Object",
      MOD, meth );
    error( ldte.ERR_KEY_FUN_NOT_FOUND );
  end
  GP=E and trace("[EXIT]<%s:%s>Key Function Result(%s)", MOD, meth,
    tostring(keyFunctionName) );
  return keyFunctionPtr;

end -- setKeyFunction()

-- -----------------------------------------------------------------------
-- setReadFunctions()()
-- -----------------------------------------------------------------------
-- Set the Filter and UnTransform Function pointers for Reading values.
-- We follow this hierarchical lookup pattern for the read filter function:
-- (*) User Supplied Module (might be different from create module)
-- (*) Create Module
-- (*) UdfFunctionTable
--
-- We follow this lookup pattern for the UnTransform function:
-- (*) Create Module
-- (*) UdfFunctionTable
-- Notice that it would be generally dangerous to use some sort of ad hoc
-- UnTransform filter -- the Transform/UnTransform should be defined at
-- the LDT Instance Creation, and then left alone.
-- Parms:
-- (*) ldtMap:
-- (*) userModule:
-- (*) filter:
-- RETURN: L_Filter, L_UnTransform, to be assigned to G_Filter, G_UnTransform
-- -----------------------------------------------------------------------
function ldt_common.setReadFunctions(ldtMap, userModule, filter )
  local meth = "setReadFunctions()";
  GP=E and trace("[ENTER]<%s:%s> userModule(%s) Filter(%s)",
    MOD, meth, tostring(userModule), tostring(filter));

  -- Do the Filter First. If not nil, then process.  Complain if things
  -- go badly.
  local createModule = ldtMap[M_UserModule];
  local L_Filter = nil;
  local userModuleRef;   -- Hold the imported user module table
  local createModuleRef; -- Hold the imported create module table
  
  if( filter ~= nil ) then
    if( type(filter) ~= "string" or filter == "" ) then
      warn("[ERROR]<%s:%s> Bad filter Name: type(%s) filter(%s)",
        MOD, meth, type(filter), tostring(filter) );
      error( ldte.ERR_FILTER_BAD );
    else
      -- Ok -- so far, looks like we have a valid filter name, 
      -- info("<CHECK><%s:%s>userModule(%s) filter(%s)", MOD, meth,
        -- tostring(userModule), tostring(filter));
      
      if( userModule ~= nil and type(userModule) == "string" ) then
        userModuleRef = require(userModule);

        -- info("[NOTE]<%s:%s> Set Filter(%s) from UserModule(%s) Ref(%s)", MOD,
        -- meth, tostring(filter), tostring(userModule), tostring(userModuleRef));

        if( userModuleRef ~= nil and userModuleRef[filter] ~= nil ) then
          L_Filter = userModuleRef[filter];
          -- info("[NOTE]<%s:%s> Set Filter(%s) from UserModule(%s)", MOD, meth,
          -- tostring(filter), tostring(userModule));
        else
          -- info("[NOTE]<%s:%s> <NO> Filter(%s) from UserMod(%s) M(%s)",MOD,meth,
          -- tostring(filter), tostring(userModule), tostring(userModuleRef));
        end
      end

      -- info("[POST USER MOD] L_Filter(%s) createModule(%s)",
        -- tostring(L_Filter), tostring(createModule));

      -- If we didn't find a good filter, keep looking.  Try the createModule.
      -- The createModule should already have been checked for validity.
      if( L_Filter == nil and createModule ~= nil ) then
        -- info("<CHECK><%s:%s>CREATE Module(%s) filter(%s)", MOD, meth,
          -- tostring(createModule), tostring(filter));

        createModuleRef = require(createModule);

        -- info("[NOTE]<%s:%s> Require UserModule(%s) Ref(%s)", MOD, meth,
          -- tostring(createModule), tostring(createModuleRef));

        if(createModuleRef ~= nil and createModuleRef[filter] ~= nil) then
          L_Filter = createModuleRef[filter];
          -- info("[NOTE]<%s:%s> Set Filter(%s) from CreateModule(%s)", MOD, meth,
          -- tostring(filter), tostring(createModule));
        else
          -- info("[NOTE]<%s:%s> <NO> Filter(%s) from CreateModule(%s)", MOD, meth,
          -- tostring(filter), tostring(CreateModule));
        end
      end
      -- Last we try the UdfFunctionTable, In case the user wants to employ
      -- one of the standard Functions.
      if( L_Filter == nil and functionTable ~= nil ) then
        L_Filter = functionTable[filter];
        -- info("[NOTE]<%s:%s> Set Filter(%s) from UdfFunctionTable(%s)",MOD,meth,
        -- tostring(filter), tostring(createModule));
      else
        -- info("[ERROR]<%s:%s> L_Filter(%s) functionTable(%s)", MOD, meth,
          -- tostring(L_Filter), tostring( functionTable ));
      end

      -- If we didn't find anything, BUT the user supplied a function name,
      -- then we have a problem.  We have to complain.
      if( L_Filter == nil ) then
        warn("[ERROR]<%s:%s> filter not found: type(%s) filter(%s)",
          MOD, meth, type(filter), tostring(filter) );
        error( ldte.ERR_FILTER_NOT_FOUND );
      end
    end
  end -- if filter not nil

  -- That wraps up the Filter handling.  Now do  the UnTransform Function.
  local untrans = ldtMap[M_UnTransform];
  local L_UnTransform = nil;
  if( untrans ~= nil ) then
    if( type(untrans) ~= "string" or untrans == "" ) then
      warn("[ERROR]<%s:%s> Bad UnTransformation Name: type(%s) function(%s)",
        MOD, meth, type(untrans), tostring(untrans) );
      error( ldte.ERR_UNTRANS_FUN_BAD );
    else
      -- Ok -- so far, looks like we have a valid untransformation func name, 
      if( createModule ~= nil ) then
        createModuleRef = require(createModule);
        if(createModuleRef ~= nil and createModuleRef[untrans] ~= nil) then
          L_UnTransform = createModuleRef[untrans];
        end
      end
      -- Last we try the UdfFunctionTable, In case the user wants to employ
      -- one of the standard Functions.
      if( L_UnTransform == nil and functionTable ~= nil ) then
        L_UnTransform = functionTable[untrans];
      end

      -- If we didn't find anything, BUT the user supplied a function name,
      -- then we have a problem.  We have to complain.
      if( L_UnTransform == nil ) then
        warn("[ERROR]<%s:%s> UnTransform Func not found: type(%s) Func(%s)",
          MOD, meth, type(untrans), tostring(untrans) );
        error( ldte.ERR_UNTRANS_FUN_NOT_FOUND );
      end
    end
  end -- if untransform not nil

  GP=E and trace("[EXIT]<%s:%s> Filter(%s) UnTransform(%s)", MOD, meth,
    tostring(L_Filter), tostring(L_UnTransform));

  return L_Filter, L_UnTransform;
end -- setReadFunctions()


-- <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> 
-- -----------------------------------------------------------------------
-- setWriteFunctions()()
-- -----------------------------------------------------------------------
-- Set the Transform Function pointer for Writing values.
-- We follow a hierarchical lookup pattern for the transform function.
-- (*) Create Module
-- (*) UdfFunctionTable
-- PARMS:
-- RETURN: L_Transform, to be assigned to G_Transform
-- -----------------------------------------------------------------------
function ldt_common.setWriteFunctions( ldtMap )
  local meth = "setWriteFunctions()";
  GP=E and trace("[ENTER]<%s:%s> ldtMap(%s)", MOD, meth, tostring(ldtMap));

  -- Look in the create module first, then the UdfFunctionTable to find
  -- the transform function (if there is one).
  local createModule = ldtMap[M_UserModule];
  local createModuleRef; -- Hold the imported module table
  local trans = ldtMap[M_Transform];
  local L_Transform;
  if( trans ~= nil ) then
    if( type(trans) ~= "string" or trans == "" ) then
      warn("[ERROR]<%s:%s> Bad Transformation Name: type(%s) function(%s)",
        MOD, meth, type(trans), tostring(trans) );
      error( ldte.ERR_TRANS_FUN_BAD );
    else
      -- Ok -- so far, looks like we have a valid transformation func name, 
      if( createModule ~= nil ) then
        createModuleRef = require(createModule);
        if(createModuleRef ~= nil and createModuleRef[trans] ~= nil) then
          L_Transform = createModuleRef[trans];
        end
      end
      -- Last we try the UdfFunctionTable, In case the user wants to employ
      -- one of the standard Functions.
      if( L_Transform == nil and functionTable ~= nil ) then
        L_Transform = functionTable[trans];
      end

      -- If we didn't find anything, BUT the user supplied a function name,
      -- then we have a problem.  We have to complain.
      if( L_Transform == nil ) then
        warn("[ERROR]<%s:%s> Transform Func not found: type(%s) Func(%s)",
          MOD, meth, type(trans), tostring(trans) );
        error( ldte.ERR_TRANS_FUN_NOT_FOUND );
      end
    end
  end

  GP=E and trace("[EXIT]<%s:%s> Transform(%s)",
    MOD, meth, tostring(L_Transform));

  return L_Transform;
end -- setWriteFunctions()

-- ======================================================================
-- <USER FUNCTIONS> - <USER FUNCTIONS> - <USER FUNCTIONS> - <USER FUNCTIONS>
-- ======================================================================


-- ======================================================================
-- propMapSummary( resultMap, propMap )
-- ======================================================================
-- Add the propMap properties to the supplied resultMap.
-- ======================================================================
function ldt_common.propMapSummary( resultMap, propMap )

  -- Fields common for all LDT's
  resultMap.PropItemCount        = propMap[PM_ItemCount];
  resultMap.PropVersion          = propMap[PM_Version];
  resultMap.PropSubRecCount      = propMap[PM_SubRecCount];
  resultMap.PropLdtType          = propMap[PM_LdtType];
  resultMap.PropBinName          = propMap[PM_BinName];
  resultMap.PropMagic            = propMap[PM_Magic];
  resultMap.PropCreateTime       = propMap[PM_CreateTime];
  resultMap.PropEsrDigest        = propMap[PM_EsrDigest];
  resultMap.RecType              = propMap[PM_RecType];
  resultMap.ParentDigest         = propMap[PM_ParentDigest];
  resultMap.SelfDigest           = propMap[PM_SelfDigest];
end -- function propMapSummary()


-- =============================
-- Begin SubRecord Function Area
-- =============================
-- ======================================================================
-- Aerospike Server Functions:
-- ======================================================================
-- Aerospike Record Functions:
-- status = aerospike:create( topRec )
-- status = aerospike:update( topRec )
-- status = aerospike:remove( rec ) (not currently used)
--
-- Aerospike SubRecord Functions:
-- newRec = aerospike:create_subrec( topRec )
-- rec    = aerospike:open_subrec( topRec, childRecDigest)
-- status = aerospike:update_subrec( childRec )
-- status = aerospike:close_subrec( childRec )
-- status = aerospike:remove_subrec( subRec )  
--
-- Record Functions:
-- digest = record.digest( childRec )
-- status = record.set_type( rec, recType )
-- status = record.set_flags( topRec, ldtBinName, binFlags )
-- ======================================================================
-- Notes on the SubRec functions:
-- (*) The underlying Aerospike SubRec mechanism actually manages most
--     aspects of SubRecs:  
--     + Update of dirty subRecs is automatic at Lua Context Close.
--     + Close of all subRecs is automatic at Lua Context Close.
-- (*) We cannot close a dirty subRec explicit (we can make the call, but
--     it will not take effect).  We must leave the closing of all dirty
--     SubRecs to the end -- and we'll make that IMPLICIT, because an
--     EXPLICIT call is just more work and makes no difference.
-- (*) It is an ERROR to try to open (with an open_subrec() call) a SubRec
--     that is ALREADY OPEN.  Thus, we use our "SubRecContext" functions
--     that manage a pool of open SubRecs -- which prevents us from making
--     that mistake.
-- (*) We have a LIMITED number of SubRecs that can be open at one time.
--     LDT Operations, such as Scan, that open ALL of the SubRecs are
--     REQUIRED to close the READ-ONLY SubRecs when they are done so that
--     we can open a new one.  We actually have two options here:
--     + We can make close implicit -- and just close clean SubRecs to 
--       free up slots in the SubRecContext (SRC: our pool of open SubRecs).
--       Note that this requires that we mark SubRecs dirty if we have
--       updated them (touched a bin).
--       The only downside is that this makes the SubRec library a little
--       more complicated.
--     + We can make it explicit -- but this means we must be sure to
--       actively close SubRecs, which makes coding more error-prone.
--
-- ======================================================================
-- SUB RECORD CONTEXT DESIGN NOTE:
-- All "outer" functions, will employ the "subrecContext" object, which
-- will hold all of the subRecords that were opened during processing. 
-- Note that some operations can potentially involve many subRec
-- operations -- and can also potentially revisit pages.
--
-- SubRecContext Design:
-- The key will be the DigestString, and the value will be the subRec
-- pointer.  At the end of an outer call, we will iterate thru the subRec
-- context and close all open subRecords.  Note that we may also need
-- to mark them dirty -- but for now we'll update them in place (as needed),
-- but we won't close them until the end.
-- ======================================================================
function ldt_common.createSubRecContext()
  local meth = "createSubRecContext()";
  GP=E and trace("[ENTER]<%s:%s>", MOD, meth );

  -- Create the Sub-Rec Context Control Structure -- a List of 2 maps.
  -- Map [1] is the Record Map (name: DigestString, Value: Rec Ptr)
  -- Map [2] is the Dirty String (name: DigestString, Value: Dirty/Clean)
  local srcCtrl = list();
  local recMap = map();
  local dirtyMap = map();

  recMap.ItemCount = 0;
  list.append( srcCtrl, recMap ); -- recMap
  list.append( srcCtrl, dirtyMap ); -- dirtyMap

  GP=E and trace("[EXIT]: <%s:%s> : SRC(%s)", MOD, meth, tostring(srcCtrl));
  return srcCtrl;
end -- createSubRecContext()

-- ======================================================================
-- cleanSRC(): Clean the Sub-Rec Context, flushing any clean Sub-Recs
-- so that we can have more slots to read new Sub-Recs.
-- We expect that we may have MANY open clean pages (from things like
-- an LDT Scan), but we should NOT have over 20 dirty Sub-Recs.
-- ======================================================================
local function cleanSRC( srcCtrl )
  local meth = "cleanSRC()";
  GP=E and trace("[ENTER]<%s:%s> src(%s)", MOD, meth, tostring(srcCtrl));



  local recMap = srcCtrl[1];
  local dirtyMap = srcCtrl[2];

  GP=F and trace("[DEBUG]<%s:%s> SRC State: IC(%d)",MOD,meth,recMap.ItemCount);

  -- Iterate thru the SubRecContext and close all CLEAN Sub-Records.
  -- Keep track of the count as we close them.
  local digestString;
  local subRec;
  local rc = 0;
  local closeCount = 0;
  for name, value in map.pairs( recMap ) do
    GP=F and trace("[DEBUG]: <%s:%s>: Processing Pair: Name(%s) Val(%s)",
      MOD, meth, tostring( name ), tostring( value ));
    if( name == "ItemCount" ) then
      GP=F and trace("[DEBUG]<%s:%s>: Processing(%d) Items", MOD, meth, value);
    else
      if ( type(name) == "string" ) then
        digestString = name;
        subRec = value;
        -- We'll assume it's a digest, since it shouldn't be anything else.
        GP=F and trace("[DEBUG]<%s:%s>: Processing Digest(%s)", MOD, meth,
          digestString );
        

        -- If this guy is CLEAN (not dirty) then we can close it and free up
        -- a slot for a NEW Sub-Rec to come in.
        local state = dirtyMap[digestString];
        if( state == DM_DIRTY or state == DM_BUSY ) then
          trace("[DEBUG]<%s:%s> Check to close (%s) Sub-Rec: Dig(%s)", MOD, meth,
            tostring( state), tostring( digestString ));
        else
          trace("[DEBUG]<%s:%s> Closing (%s) Sub-Rec: Dig(%s)", MOD, meth,
            tostring( state), tostring( digestString ));
          rc = aerospike:close_subrec( subRec );
          if( rc ~= nil and rc < 0 ) then
            warn("[ERROR]<%s:%s> Error closing SubRec: rc(%s) Digest(%s)",
            MOD, meth, tostring(rc), tostring( digestString ));
          else
            -- We're ok.  It's closed.  Decrement the count and free up the
            -- slot.

            dirtyMap[digestString] = nil;
            recMap[digestString] = nil;
            local itemCount = recMap.ItemCount;
            recMap.ItemCount = itemCount - 1;
            closeCount = closeCount + 1;

            GP=F and trace("[DEBUG]<%s:%s> Closed(%s) RM(%s) IC(%d) CC(%d)",
            MOD, meth, digestString, tostring(recMap[digestString]),
            recMap.ItemCount, closeCount );
          end
        end -- else we have something to close
      end -- it's the right type for a Digest Field.
    end -- else it's (assumed to be) a Sub-Rec Field in recMap
  end -- for all fields in SRC

  GP=E and trace("[EXIT]<%s:%s> POST CLEAN: CloseCnt(%d) ItemCount(%d)",
  MOD, meth, closeCount, recMap.ItemCount );

end -- cleanSRC()

-- ======================================================================
-- Given an already opened subRec (probably one that was recently created),
-- add it to the subRec context.  As assume, for now, that the SubRec
-- is already Dirty (most will be).
-- Parms:
-- (*) srcCtrl: The
-- (*) digest: The actual digest of the record.  We will "stringify" it.
-- (*) dirty: Boolean that says if this SubRec is already Dirty.
-- ======================================================================
function ldt_common.addSubRecToContext( srcCtrl, subRec, dirty )
  local meth = "addSubRecContext()";
  GP=E and trace("[ENTER]<%s:%s> src(%s)", MOD, meth, tostring( srcCtrl));

  if( srcCtrl == nil ) then
    warn("[ERROR]<%s:%s> Bad SubRec Context: SRC is NIL", MOD, meth );
    error( ldte.ERR_INTERNAL );
  end

  local recMap = srcCtrl[1];
  local dirtyMap = srcCtrl[2];

  local digest = record.digest( subRec );
  local digestString = tostring( digest );
  recMap[digestString] = subRec;
  if( dirty ~= nil and dirty == true ) then
    dirtyMap[digestString] = DM_DIRTY;
  else
    dirtyMap[digestString] = DM_BUSY;
  end

  local itemCount = recMap.ItemCount;
  recMap.ItemCount = itemCount + 1;

  GP=E and trace("[EXIT]: <%s:%s> : SRC(%s)", MOD, meth, tostring(srcCtrl));
  return 0;
end -- addSubRecToContext()

-- ======================================================================
-- Create and Init ESR
-- ======================================================================
-- The Existence SubRecord is the synchronization point for the lDTs that
-- have multiple records (one top rec and many children).  It's a little
-- like the baby sitter for the children -- it helps keeps track of them.
-- And, when the ESR is gone, we kill the children. (BRUA-HAHAHAH!!!)
--
-- All LDT Sub-Recs have a properties bin that describes the Sub-Rec.  This
-- bin contains a map that is "un-msg-packed" by the C code on the server
-- and read.  It must be the same for all LDT recs.
--
-- ======================================================================
function ldt_common.createAndInitESR(srcCtrl, topRec, ldtCtrl )
  local meth = "createAndInitESR()";
  GP=E and trace("[ENTER]: <%s:%s>", MOD, meth );

  local rc = 0;

  -- Since this function is called from "createSubRec()" we need to
  -- "bare-hand" this Special SubRec create.
  -- Create the ESR, then Remember to add this to the SRC after it is
  -- initialized.
  -- GP=F and info("[DEBUG]: <%s:%s> Calling CREATE", MOD, meth );
  local esrRec    = aerospike:create_subrec( topRec );

  if( esrRec == nil ) then
    warn("[ERROR]<%s:%s> Problems Creating ESR", MOD, meth );
    error( ldte.ERR_SUBREC_CREATE );
  end

  -- GP=F and info("[DEBUG]: <%s:%s> Setting ESR TYPE ", MOD, meth );

  -- Set the record type as "ESR"
  record.set_type( esrRec, RT_ESR );

  -- GP=F and info("[DEBUG]: <%s:%s> Setting ESR BINS ", MOD, meth );

  local esrDigest = record.digest( esrRec);
  local topDigest = record.digest( topRec );
  local topPropMap = ldtCtrl[1];

  -- GP=F and info("[DEBUG]: <%s:%s> topPropMap(%s) ", MOD, meth, tostring(topPropMap));

  -- Set the Property ControlMap for the ESR, and assign the parent Digest
  -- Note that we use our standard convention for property maps - all Sub-Recs
  -- have a property map.
  -- Init the properties map for this ESR. Note that esrDigest is in here
  -- twice -- once for "self" and once for "esrRec".
  local esrPropMap = map();

  -- Remember the ESR in the Top Record
  topPropMap[PM_EsrDigest] = esrDigest;

  -- GP=F and info("[DEBUG]: <%s:%s> ESR DG(%s) ", MOD, meth, tostring(esrDigest));

  -- Initialize the PropertyMap in the new ESR
  esrPropMap[PM_EsrDigest]    = esrDigest;
  esrPropMap[PM_RecType]      = RT_ESR;
  esrPropMap[PM_Magic]        = MAGIC;
  esrPropMap[PM_ParentDigest] = topDigest;
  esrPropMap[PM_SelfDigest]   = esrDigest;

  -- Even though the ESR is really IMPLICIT, we'll add it to the total
  -- SubRec Count.  Also, this SHOULD be the FIRST SubRec, and as a result,
  -- the SubRec count might be nil.  Double check that.
  local subRecCount = topPropMap[PM_SubRecCount];
  if ( subRecCount == nil ) then
    subRecCount = 0;
  end
  topPropMap[PM_SubRecCount] = subRecCount + 1;

  -- NOTE: We have to make sure that the TopRec propMap also gets saved.
  esrRec[SUBREC_PROP_BIN] = esrPropMap;

  -- NOTE: We no longer Update the ESR early.  It gets written and closed
  -- when the Lua Context closes.
  -- However, for testing purposes, we allow EARLY subrec Updates.
  if DO_EARLY_SUBREC_UPDATES then
    -- Update the ESR.  We're done with it (but updated SubRecs can't be closed
    -- TEMPORARILY -- WRITE OUT THE SUBREC, esp the ESR.
    trace("[NOTE]<%s:%s> Performing Direct Update of ESR subRec", MOD,meth);
    rc = aerospike:update_subrec( esrRec );
    if( rc ~= nil and rc == 0 ) then
      warn("[ERROR]<%s:%s>Problems Updating ESR rc(%s)",MOD,meth,tostring(rc));
      error( ldte.ERR_SUBREC_UPDATE );
    end
  end
 
  -- Add this open ESR SubRec to our SubRec Context, which implicitly 
  -- marks it as dirty.
  GP=D and trace("[ENTER]<%s:%s> Add ESR to SRC", MOD, meth );
  ldt_common.addSubRecToContext( srcCtrl, esrRec, true );

  GP=E and trace("[EXIT]: <%s:%s> Leaving with ESR Digest(%s)",
    MOD, meth, tostring(esrDigest));
  return esrDigest;

end -- createAndInitESR()

-- ======================================================================
-- createSubRec(): 
-- ======================================================================
-- Create and initialize a new SubRec. This function covers the general
-- function needed for ALL subRecs.  Any specific data management, such
-- as use-specific items (e.g. LStack Cold Dir, LList Root Node) are 
-- handled by the caller.  We just do the common stuff here, and we also
-- plug the new SubRec into the SRC.
-- ======================================================================
function ldt_common.createSubRec( srcCtrl, topRec, ldtCtrl, recType )
  local meth = "createSubRec()";
  GP=E and trace("[ENTER]<%s:%s> ", MOD, meth );

  -- We have a global limit on the number of subRecs that we can have
  -- open at a time.  If we're at (or above) the limit, then we must
  -- exit with an error (better here than in the subRec code).
  local recMap = srcCtrl[1];
  local dirtyMap = srcCtrl[2];
  local itemCount = recMap.ItemCount;
  local rc = 0;

  -- Access the TopRec Control Maps
  local propMap = ldtCtrl[1];
  local ldtMap = ldtCtrl[2];

  -- Set up the SubRec Control Maps
  local subRecPropMap = map();

  local esrDigest;

  -- If this is the FIRST SubRec (i.e. There is NOT already an ESR), then
  -- we will create the ESR first, then create this first SubRec.
  -- There is one ESR created per LMAP bin, not per Sub-Rec.
  if( propMap[PM_EsrDigest] == nil or propMap[PM_EsrDigest] == 0 ) then
    GP=F and trace("[DEBUG]<%s:%s> First ESR creation for LDT bin",MOD, meth);
    esrDigest = ldt_common.createAndInitESR( srcCtrl, topRec,ldtCtrl);
    propMap[PM_EsrDigest] = esrDigest;
  else
    esrDigest = propMap[PM_EsrDigest];
  end
  subRecPropMap[PM_EsrDigest] = esrDigest;

  -- Check our counts -- if we don't have room for another open rec,
  -- we should try a "CLEAN" to free up some slots.  If that fails, then
  -- we're screwed.  Notice that "createESR" doesn't need to check the
  -- counts because by definition it's the FIRST SUB-REC.
  GD=DEBUG and trace("[DEBUG]<%s:%s> SR Limit: IC(%d)", MOD, meth, itemCount);
  if( itemCount >= G_OPEN_SR_LIMIT ) then
    cleanSRC( srcCtrl ); -- Flush the clean pages.  Ignore errors.
    -- Not sure if I need to do this, but just in case.
    -- Reaccess the srcCtrl structure from the top.
    GD=DEBUG and trace("[DEBUG]<%s:%s> SRC(%s)", MOD, meth, tostring(srcCtrl));

    if( recMap.ItemCount >= G_OPEN_SR_LIMIT ) then
      warn("[ERROR]<%s:%s> SRC Count(%d) Exceeded Limit(%d)", MOD, meth,
        recMap.ItemCount, G_OPEN_SR_LIMIT );
      error( ldte.ERR_TOO_MANY_OPEN_SUBRECS );
    end
  end

  local newSubRec = aerospike:create_subrec( topRec );
  if( newSubRec == nil ) then
    warn("[ERROR]<%s:%s>Problems Creating New Subrec (%s)", MOD,meth );
    error( ldte.ERR_SUBREC_CREATE );
  end
  record.set_type( newSubRec, RT_SUB ); -- Always RT_SUB for this call.

  local subRecDigest = record.digest( newSubRec );
  local topRecDigest = record.digest( topRec );
  local subRecDigestString = tostring( subRecDigest );
  
  -- Recalc ItemCount after the clean.
    itemCount = recMap.ItemCount;
  -- WE DO NOT NEED TO  BUMP ITEM COUNT HERE -- THAT IS DONE WHEN WE ADD
  -- THIS TO THE CONTEXT.
--  recMap.ItemCount = itemCount + 1;

  GP=F and trace("[CREATE SUBREC]<%s:%s>New SRC.ItemCount(%d) DigStr(%s)",
    MOD, meth, recMap.ItemCount, subRecDigestString );

  -- topRec's digest is the parent digest for this new Sub-Rec 
  subRecPropMap[PM_ParentDigest] = topRecDigest;

  -- Subrec's (its own) digest is the selfDigest :)
  -- I think we need to STOP saving SELF DIGEST (Verify Raj doesn't need it)
  subRecPropMap[PM_SelfDigest]   = subRecDigest;
  subRecPropMap[PM_Magic]        = MAGIC;
  subRecPropMap[PM_RecType]      = recType; -- This might always be RT_SUB
  subRecPropMap[PM_CreateTime]   = aerospike:get_current_time();
  subRecPropMap[PM_EsrDigest]    = esrDigest;

  newSubRec[SUBREC_PROP_BIN] = subRecPropMap;

  -- NOTE: We no longer Update the SubRecs early.  They get written and closed
  -- when the Lua Context closes.
  -- However, for testing purposes, we allow EARLY subrec Updates.
  if DO_EARLY_SUBREC_UPDATES then
    -- TEMPORARILY -- WRITE OUT THE SUBREC.
    trace("[NOTE]<%s:%s> Performing Direct Update of subRec", MOD,meth);
    rc = aerospike:update_subrec( newSubRec );
    if( rc ~= nil and rc == 0 ) then
      warn("[ERROR]<%s:%s>Problems Updating ESR rc(%s)",MOD,meth,tostring(rc));
      error( ldte.ERR_SUBREC_UPDATE );
    end
  end
 
  -- Update the LDT sub-rec count.  Remember that any changes to a record
  -- are remembered until the final Lua Close, then the record(s) will be
  -- flushed to storage.
  local subRecCount = propMap[PM_SubRecCount];
  propMap[PM_SubRecCount] = subRecCount + 1;
  -- This will mark the SubRec as dirty.
  local rc = ldt_common.addSubRecToContext( srcCtrl, newSubRec, true);

  GP=E and trace("[EXIT]<%s:%s> with a new SubRec: Dig(%s)", MOD, meth,
    subRecDigestString );
  return newSubRec;
end --  createSubRec()

-- ======================================================================
-- openSubRec()
-- ======================================================================
-- Return a ptr to the Open Sub-Rec.  We either find the Sub-Rec in our
-- table of open Sub-Recs, or we Open a new one.  If we reach the limit
-- of open Sub-Recs (last known size of the limit was 20), then we try
-- to find a CLEAN Sub-Rec and close it.  Note that we cannot close
-- a dirty Sub-Rec -- that is an error.  Also, it is an error to try
-- to open an existing open Sub-Rec, so that's why we have this pool
-- in the first place.
-- Parms:
-- srcCtrl: the Sub-Record Control Structure
-- topRec: The Aerospike Record holding the LDT that uses Sub-Recs.
-- digestString: The identifier of the Sub-Rec.
--
-- ======================================================================
function ldt_common.openSubRec( srcCtrl, topRec, digestString )
  local meth = "openSubRec()";
  GP=E and trace("[ENTER]<%s:%s> TopRec(%s) DigestStr(%s) SRC(%s)",
    MOD, meth, tostring(topRec), tostring(digestString), tostring(srcCtrl));

  -- Do some checks while we're in DEBUG mode.
  if( digestString == nil ) then
    warn("[ERROR]<%s:%s> NIL DigestString", MOD, meth );
    error( ldte.ERR_INTERNAL );
  end
  if( type(digestString) ~= "string" ) then
    warn("[ERROR]<%s:%s> Parm DigestString is NOT a string. It is(%s)",
        MOD, meth, type(digestString));
    error( ldte.ERR_INTERNAL );
  end
  -- We have a global limit on the number of subRecs that we can have
  -- open at a time.  If we're at (or above) the limit, then we must
  -- exit with an error (better here than in the subRec code).
  local recMap = srcCtrl[1];
  local dirtyMap = srcCtrl[2];
  local itemCount = recMap.ItemCount;

  local rc = 0;

  -- First, look to see if the Sub-Rec is already open.  If so, then
  -- return the Sub-Rec ptr.
  -- If not, see if we can open a new Sub-Rec easily.
  -- If we are at the limit, then do a clean before we open.
  GP=F and trace("[DEBUG]<%s:%s> Looking for DG(%s) in SRC(%s)", MOD, meth,
    tostring(digestString), tostring(srcCtrl));

  local subRec = recMap[digestString];
  if( subRec == nil ) then
    GD=DEBUG and
      trace("[Notice]<%s:%s>Did NOT find DG(%s) in the recMap(%s)", MOD, meth,
        tostring(digestString), tostring( recMap ));

    if( itemCount >= G_OPEN_SR_LIMIT ) then
      cleanSRC( srcCtrl ); -- Flush the clean pages.  Ignore errors.
      if( recMap.ItemCount >= G_OPEN_SR_LIMIT ) then
        warn("[ERROR]<%s:%s> SRC Count(%d) Exceeded Limit(%d): After clean",
            MOD, meth, itemCount, G_OPEN_SR_LIMIT );
        error( ldte.ERR_TOO_MANY_OPEN_SUBRECS );
      end
    end

    -- Recalc ItemCount after the (possible) clean.
    itemCount = recMap.ItemCount;
  -- WE DO NOT NEED TO  BUMP ITEM COUNT HERE -- THAT IS DONE WHEN WE ADD
  -- THIS TO THE CONTEXT.
--     recMap.ItemCount = itemCount + 1;
    GP=F and trace("[OPEN SUBREC]<%s:%s>SRC.ItemCount(%d) TR(%s) DigStr(%s)",
      MOD, meth, recMap.ItemCount, tostring(topRec), tostring(digestString));
    subRec = aerospike:open_subrec( topRec, digestString );
    GP=F and trace("[OPEN SUBREC RESULTS]<%s:%s>(%s)", 
      MOD,meth,tostring(subRec));
    if( subRec == nil ) then
      warn("[ERROR]<%s:%s> SubRec Open Failure: Digest(%s)", MOD, meth,
        digestString );
      error( ldte.ERR_SUBREC_OPEN );
    end
    -- Add this open SubRec to our SubRec Context.
    local rc = ldt_common.addSubRecToContext( srcCtrl, subRec, false);

  else
    -- FOUND IT!!  No new SubRec open.
    GP=F and trace("[FOUND REC]<%s:%s>Rec DG(%s)", MOD, meth, digestString);
  end

  GP=E and trace("[EXIT]<%s:%s>Rec(%s) Dig(%s)",
    MOD, meth, tostring(subRec), digestString );
  return subRec;
end -- openSubRec()

-- ======================================================================
-- closeSubRecDigestString()
-- ======================================================================
-- Close the sub-Record -- providing it is NOT dirty.  For all dirty
-- sub-Records, we have to wait until the end of the UDF call, as THAT is
-- when all dirty sub-Records get written out and closed.
--
-- ALSO, for PRODUCTION USE, we do not actually close the records here,
-- but instead we mark them as no longer busy -- which will make it possible
-- to close it when we issue a CLEAN on the Sub-Rec Pool.
-- Parms:
-- (*) srcCtrl:
-- (*) digestString:
-- (*) dirty: Optional Parm: True or other (false or nil)
-- ======================================================================
function ldt_common.closeSubRecDigestString( srcCtrl, digestString, dirty)
  local meth = "closeSubRecDigestString()";
  GP=E and trace("[ENTER]<%s:%s> DigestStr(%s) SRC(%s)",
    MOD, meth, tostring(digestString), tostring(srcCtrl));

  local recMap = srcCtrl[1];
  local dirtyMap = srcCtrl[2];
  local itemCount = recMap.ItemCount;
  local rc = 0;

  local subRec = recMap[digestString];
  if( subRec == nil ) then
    warn("[INTERNAL ERROR]<%s:%s> Rec not found for Digest(%s) in map(%s)",
      MOD, meth, tostring(digestString), tostring(recMap));
    error( ldte.ERR_INTERNAL );
  end

  GP=F and trace("[STATUS]<%s:%s> Closing Rec: Digest(%s) IC(%d)", MOD, meth,
    digestString, itemCount );

  if dirty == nil then
    dirty = false;
  end

  local dirtyStatus = (dirtyMap[digestString] == DM_DIRTY) or dirty;

  if( dirtyStatus ) then
    GP=F and trace("[NOTICE]<%s:%s> Can't close Dirty Record(%s) St(%s)",
      MOD, meth, digestString, tostring(dirtyStats));
  else
    rc = aerospike:close_subrec( subRec );
    -- Now erase this subrec from the SRC maps.
    recMap[digestString] = nil;
    dirtyMap[digestString] = nil;
    recMap.ItemCount = itemCount - 1;
    GP=F and trace("[STATUS]<%s:%s>Closed Rec: Digest(%s) IC(%d) rc(%s)",
      MOD, meth, digestString, recMap.ItemCount, tostring( rc ));
  end

  GP=E and trace("[EXIT]<%s:%s>Rec(%s) Dig(%s) rc(%s)",
    MOD, meth, tostring(subRec), tostring(digestString), tostring(rc));
  -- TODO: close_subrec() is apparently returning NIL right now -- must fix.
  return 0;
end -- closeSubRecDigestString()

-- ======================================================================
-- closeSubRec(): Given a Sub-Rec ptr, close the subRec.
-- ======================================================================
function ldt_common.closeSubRec( srcCtrl, subRec, dirty )
  local meth = "closeSubRec";
  if( subRec == nil ) then
    warn("[ERROR]<%s:%s> NULL subRec", MOD, meth );
    error( ldte.ERR_INTERNAL );
  end

  local digest = record.digest( subRec );
  local digestString = tostring( digest );
  if( digestString == nil ) then
    warn("[ERROR]<%s:%s> INVALID subRec", MOD, meth );
    error( ldte.ERR_INTERNAL );
  end

  return ldt_common.closeSubRecDigestString( srcCtrl, digestString, dirty );
end -- closeSubRec()


-- ======================================================================
-- markUnBusy()
-- ======================================================================
-- Do not close the sub-rec, but instead mark the sub-rec as NOT BUSY if
-- it is currently "DM_BUSY" (as in, "in use").  When it comes time to clean,
-- we can safely close any non-busy sub-recs, but we cannot close dirty ones.
-- Parms:
-- (*) srcCtrl:
-- (*) digestString:
-- ======================================================================
function ldt_common.markUnBusy( srcCtrl, digestString )
  local meth = "markUnBusy()";
  GP=E and trace("[ENTER]<%s:%s> DigestStr(%s) SRC(%s)",
    MOD, meth, tostring(digestString), tostring(srcCtrl));

  local recMap = srcCtrl[1];
  local dirtyMap = srcCtrl[2];
  local rc = 0;

  local subRec = recMap[digestString];
  if( subRec == nil ) then
    warn("[INTERNAL ERROR]<%s:%s> Rec not found for Digest(%s) in map(%s)",
      MOD, meth, tostring(digestString), tostring(recMap));
    error( ldte.ERR_INTERNAL );
  end

  local cleaned = 0;
  local subRecStatus = dirtyMap[digestString];
  if( subRecStatus ~= nil and subRecStatus == DM_BUSY ) then
    dirtyMap[digestString] = nil;
    cleaned = 1;
  end

  GP=E and trace("[EXIT]<%s:%s> Digest(%s) Cleaned(%d)",
    MOD, meth, tostring(digestString), cleaned);
  return 0;
end -- markUnBusy()

-- ======================================================================
-- updateSubRec()
-- ======================================================================
-- Update the subRecord -- and then mark it dirty.
-- ======================================================================
function ldt_common.updateSubRec( srcCtrl, subRec )
  local meth = "updateSubRec()";
  GP=E and trace("[ENTER]<%s:%s> SRC(%s) subRec(%s)",
    MOD, meth, tostring(srcCtrl), tostring(subRec));

  local recMap = srcCtrl[1];
  local dirtyMap = srcCtrl[2];
  local rc = 0;

  if( subRec == nil ) then
    warn("[ERROR]<%s:%s> Unexpected nil value for subRec", MOD, meth);
    error( ldte.ERR_INTERNAL );
  end

  local digest = record.digest( subRec );
  local digestString = tostring( digest );

  -- NOTE: We no longer Update the SubRecs early.  They get written and closed
  -- when the Lua Context closes.
  -- However, for testing purposes, we allow EARLY subrec Updates.
  if DO_EARLY_SUBREC_UPDATES then
    -- TEMPORARILY -- WRITE OUT THE SUBREC.
    trace("[NOTE]<%s:%s> Performing Direct Update of subRec", MOD,meth);
    rc = aerospike:update_subrec( subRec );
    if( rc ~= nil and rc == 0 ) then
      warn("[ERROR]<%s:%s>Problems Updating ESR rc(%s)",MOD,meth,tostring(rc));
      error( ldte.ERR_SUBREC_UPDATE );
    end
  end

  -- Note that we DO NOT want to update the SubRec before the END of the
  -- Lua Call Context.  However, we DO have to mark the record as DIRTY
  -- so that we don't try to close it when we're looking for available
  -- slots when trying to close a clean Sub-Rec.

  dirtyMap[digestString] = DM_DIRTY;

  GP=E and trace("[EXIT]<%s:%s>Rec(%s) Dig(%s) rc(%s)",
    MOD, meth, tostring(subRec), digestString, tostring(rc));
  return rc;
end -- updateSubRec()

-- ======================================================================
-- markSubRecDirty()
-- ======================================================================
function ldt_common.markSubRecDirty( srcCtrl, digestString )
  local meth = "markSubRecDirty()";
  GP=E and trace("[ENTER]<%s:%s> src(%s)", MOD, meth, tostring(srcCtrl));

  -- Pull up the dirtyMap, find the entry for this digestString and
  -- mark it dirty.  We don't even care what the existing value used to be.
  local recMap = srcCtrl[1];
  local dirtyMap = srcCtrl[2];

  dirtyMap[digestString] = DM_DIRTY;
  
  GP=E and trace("[EXIT]<%s:%s> SRC(%s)", MOD, meth, tostring(srcCtrl) );
  return 0;
end -- markSubRecDirty()

-- ======================================================================
-- closeAllSubRecs()
-- ======================================================================
-- Close all Read-only Sub-Recs, because that's how we free up Sub-Recs
-- that we know are no longer busy.
-- ======================================================================
function ldt_common.closeAllSubRecs( srcCtrl )
  local meth = "closeAllSubRecs()";
  GP=E and trace("[ENTER]<%s:%s> src(%s)", MOD, meth, tostring(srcCtrl));

  local recMap = srcCtrl[1];
  local dirtyMap = srcCtrl[2];

  -- Iterate thru the SubRecContext and close all Sub-Records.
  local digestString;
  local rec;
  local rc = 0;
  for name, value in map.pairs( recMap ) do
    GP=F and trace("[DEBUG]: <%s:%s>: Processing Pair: Name(%s) Val(%s)",
      MOD, meth, tostring( name ), tostring( value ));
    if( name == "ItemCount" ) then
      GP=F and trace("[DEBUG]<%s:%s>: Processing(%d) Items", MOD, meth, value);
    else
      digestString = name;
      rec = value;
      GP=F and trace("[DEBUG]<%s:%s>: Marking UNBUSY: SubRec(%s) Rec(%s)",
      MOD, meth, digestString, tostring(rec) );
      ldt_common.markUnBusy( srcCtrl, digestString );
    end
  end -- for all fields in SRC

  GP=E and trace("[EXIT]: <%s:%s> : RC(%s)", MOD, meth, tostring(rc) );
  return 0; -- Mask the error for now:: TODO::@TOBY::Figure this out.
end -- closeAllSubRecs()

-- ======================================================================
-- Remove this SubRec from the pool and also close system subrecRemove()
-- ======================================================================
function ldt_common.removeSubRec( srcCtrl, digestString )
  local meth = "removeSubRec()";
  GP=E and trace("[ENTER]<%s:%s> src(%s) DigestStr(%s)", MOD, meth,
    tostring(srcCtrl), tostring(digestString));

  local recMap = srcCtrl[1];
  local dirtyMap = srcCtrl[2];

  -- If the subRec digestString is valid, then remove it from the SRC and
  -- make the call to actually remove the SubRec.
  if ( digestString == nil or type(digestString) ~= "string" ) then
    info("[WARNING]<%s:%s> Attempt to remove invalid SubRec(%s)", MOD, meth,
      tostring(digestString));
    return -1;
  end

  -- If it's not already open, which is possible, then try to open it,
  -- because apparently we can remove only open sub-recs.
  local subRec = recMap[digestString];
  if ( subRec ~= nil ) then
    if ( recMap[digestString] ~= nil ) then
      -- We can do this blind -- since whether or not it's there, we're removing
      -- it from both maps.
      dirtyMap[digestString] = nil;
      recMap[digestString] = nil;
      local itemCount = recMap.ItemCount;
      recMap.ItemCount = itemCount - 1;
    end
  else
    GP=F and trace("[DEBUG]<%s:%s> remove non-open SubRec(%s)", MOD, meth,
      tostring(digestString));
    subRec = aerospike:open_subrec( topRec, digestString );
  end

  local rc = aerospike:remove_subrec( subRec );

  GP=E and trace("[EXIT]: <%s:%s> : RC(%s)", MOD, meth, tostring(rc) );
  return rc; -- Mask the error for now:: TODO::@TOBY::Figure this out.
end -- removeSubRec()

-- ===========================
-- End SubRecord Function Area
-- ===========================

-- ======================================================================
-- listAppendList()
-- ======================================================================
-- General tool to append one list to another.   At the point that we
-- find a better/cheaper way to do this, then we change THIS method and
-- all of the LDT calls to handle lists will get better as well.
-- ======================================================================
function ldt_common.listAppendList( baseList, additionalList )
  local returnList;
  if( baseList == nil ) then
    warn("[INTERNAL ERROR] Null baselist in listAppend()" );
    -- error( ldte.ERR_INTERNAL );
    returnList = additionalList;
  end

  local listSize = list.size( additionalList );
  for i = 1, listSize, 1 do
    list.append( baseList, additionalList[i] );
  end -- for each element of additionalList
  returnList = baseList;

  return returnList;
end -- listAppendList()

-- ======================================================================
-- When we create the initial LDT Control Bin for the entire record (the
-- first time ANY LDT is initialized in a record), we create a property
-- map in it with various values.
-- ======================================================================
function ldt_common.setLdtRecordType( topRec )
  local meth = "setLdtRecordType()";
  GP=E and trace("[ENTER]<%s:%s>", MOD, meth );

  local rc = 0;
  local recPropMap;

  -- Check for existence of the main record control bin.  If that exists,
  -- then we're already done.  Otherwise, we create the control bin, we
  -- set the topRec record type (to LDT) and we praise the lord for yet
  -- another miracle LDT birth.
  if( topRec[REC_LDT_CTRL_BIN] == nil ) then
    GP=F and trace("[DEBUG]<%s:%s>Creating Record LDT Map", MOD, meth );

    -- If this record doesn't even exist yet -- then create it now.
    -- Otherwise, things break.
    if( not aerospike:exists( topRec ) ) then
      GP=F and trace("[DEBUG]:<%s:%s>:Create Record()", MOD, meth );
      rc = aerospike:create( topRec );
      if( rc ~= 0 ) then
        warn("[ERROR]<%s:%s>Problems Creating TopRec rc(%d)", MOD, meth, rc );
        error( ldte.ERR_TOPREC_CREATE );
      end
    end

    record.set_type( topRec, RT_LDT );
    recPropMap = map();
    -- vinfo will be a 5 byte value, but it will be easier for us to store
    -- a FULL NUMBER (8 bytes) of value ZERO.
    local vinfo = 0;
    recPropMap[RPM_VInfo] = vinfo; 
    recPropMap[RPM_LdtCount] = 1; -- this is the first one.
    recPropMap[RPM_Magic] = MAGIC;
  else
    -- Not much to do -- increment the LDT count for this record.
    recPropMap = topRec[REC_LDT_CTRL_BIN];
    local ldtCount = recPropMap[RPM_LdtCount];
    recPropMap[RPM_LdtCount] = ldtCount + 1;
    GP=F and trace("[DEBUG]<%s:%s>Record LDT Map Exists: Bump LDT Count(%d)",
      MOD, meth, ldtCount + 1 );
  end

  topRec[REC_LDT_CTRL_BIN] = recPropMap;
  -- Set this control bin as HIDDEN
  record.set_flags(topRec, REC_LDT_CTRL_BIN, BF_LDT_HIDDEN );

  -- Now that we've changed the top rec, do the update to make sure the
  -- changes are saved.
  rc = aerospike:update( topRec );
  if( rc ~= 0 ) then
    warn("[ERROR]<%s:%s>Problems Updating TopRec rc(%d)", MOD, meth, rc );
    error( ldte.ERR_TOPREC_UPDATE );
  end

  GP=E and trace("[EXIT]<%s:%s> rc(%d)", MOD, meth, rc );
  return rc;
end -- setLdtRecordType()
-- ======================================================================
-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- LDT Utility Functions
-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- ======================================================================
-- ======================================================================
-- These are all utility functions that perform various useful tasks.
-- ======================================================================
--
-- ======================================================================
-- adjustLdtMap:
-- ======================================================================
-- Using the settings supplied by the caller in the stackCreate call,
-- we adjust the values in the LdtMap:
-- Parms:
-- (*) ldtCtrl: the main LDT Bin value (propMap, ldtMap)
-- (*) argListMap: Map of LDT Settings 
-- (*) ldtSpecificPackage: The LDT-Specific package of settings
-- Return: The updated LsoList
-- ======================================================================
function ldt_common.adjustLdtMap( ldtCtrl, argListMap, ldtSpecificPackage )
  local meth = "adjustLdtMap()";
  local propMap = ldtCtrl[1];
  local ldtMap = ldtCtrl[2];

  GP=E and trace("[ENTER]<%s:%s>:: LDT Ctrl(%s)::\n ArgListMap(%s)",
    MOD, meth, tostring(ldtCtrl), tostring( argListMap ));

  -- Iterate thru the argListMap and adjust (override) the map settings 
  -- based on the settings passed in during the stackCreate() call.
  GP=F and trace("[DEBUG]: <%s:%s> : Processing Arguments:(%s)",
    MOD, meth, tostring(argListMap));

  -- For the old style -- we'd iterate thru ALL arguments and change
  -- many settings.  Now we process only packages this way.
  for name, value in map.pairs( argListMap ) do
    GP=F and trace("[DEBUG]: <%s:%s> : Processing Arg: Name(%s) Val(%s)",
    MOD, meth, tostring( name ), tostring( value ));
  
    -- Process our "prepackaged" settings.  These now reside in the
    -- settings file.  All of the packages are in a table, and thus are
    -- looked up dynamically.
    -- Notice that this is the old way to change settings.  The new way is
    -- to use a "user module", which contains UDFs that control LDT settings.
    if name == "Package" and type( value ) == "string" then
      local ldtPackage = ldtSpecificPackage[value];
      if( ldtPackage ~= nil ) then
        ldtPackage( ldtMap );
      end
    end
  end -- for each argument

  GP=E and trace("[EXIT]:<%s:%s>:LsoList after Init(%s)",
    MOD,meth,tostring(ldtCtrl));
  return ldtCtrl;
end -- adjustLdtMap

-- ======================================================================
-- validateBinName()
-- ======================================================================
-- validateBinName(): Validate that the user's bin name for this large
-- object complies with the rules of Aerospike. Currently, a bin name
-- cannot be larger than 14 characters (a seemingly low limit).
-- ======================================================================
function ldt_common.validateBinName( ldtBinName )
  local meth = "ldt_common.validateBinName()";
  GP=E and trace("[ENTER]: <%s:%s> validate Bin Name(%s)",
      MOD, meth, tostring(ldtBinName));

  if ldtBinName == nil  then
    warn("[ERROR EXIT]:<%s:%s> Null Bin Name", MOD, meth );
    error( ldte.ERR_NULL_BIN_NAME );
  elseif type( ldtBinName ) ~= "string"  then
    warn("[ERROR EXIT]:<%s:%s> Bin Name Not a String", MOD, meth );
    error( ldte.ERR_BIN_NAME_NOT_STRING );
  elseif string.len( ldtBinName ) > 14 then
    warn("[ERROR EXIT]:<%s:%s> Bin Name Too Long", MOD, meth );
    error( ldte.ERR_BIN_NAME_TOO_LONG );
  end
  GP=E and trace("[EXIT]:<%s:%s> Ok", MOD, meth );
end -- ldt_common.validateBinName

-- ======================================================================
-- validateRecBinAndMap():
-- Check that the topRec, the ldtBinName and ldtMap are valid, otherwise
-- jump out with an error() call.
--
-- Parms:
-- (*) topRec:
-- (*) ldtBinName: User's Name for the LDT Bin
-- (*) mustExist: When true, ldtCtrl must exist, otherwise error
-- (*) ldtType: Caller must tell us the type of LDT
-- (*) codeVersion: Caller must tell us the Version of the LDT Code
-- Return:
--   ldtCtrl -- if "mustExist" is true, otherwise unknown.
-- ======================================================================
function
ldt_common.validateRecBinAndMap(topRec,ldtBinName,mustExist,ldtType,codeVersion)
  local meth = "ldt_common.validateRecBinAndMap()";
  GP=E and trace("[ENTER]:<%s:%s> BinName(%s) ME(%s)",
    MOD, meth, tostring( ldtBinName ), tostring( mustExist ));

  -- Start off with validating the bin name -- because we might as well
  -- flag that error first if the user has given us a bad name.
  ldt_common.validateBinName( ldtBinName );

  local ldtCtrl;
  local propMap;

  -- If "mustExist" is true, then several things must be true or we will
  -- throw an error.
  -- (*) Must have a record.
  -- (*) Must have a valid Bin
  -- (*) Must have a valid Map in the bin.
  --
  -- Otherwise, If "mustExist" is false, then basically we're just going
  -- to check that our bin includes MAGIC, if it is non-nil.
  -- TODO : Flag is true for get, config, size, delete etc 
  -- Those functions must be added b4 we validate this if section 

  if mustExist then
    -- Check Top Record Existence.
    if( not aerospike:exists( topRec ) ) then
      warn("[ERROR EXIT]:<%s:%s>:Missing Record. Exit", MOD, meth );
      error( ldte.ERR_TOP_REC_NOT_FOUND );
    end
     
    -- Control Bin Must Exist, in this case, ldtCtrl is what we check.
    if ( not  topRec[ldtBinName] ) then
      warn("[ERROR EXIT]<%s:%s> LDT BIN (%s) DOES NOT Exists",
            MOD, meth, tostring(ldtBinName) );
      error( ldte.ERR_BIN_DOES_NOT_EXIST );
    end

    -- check that our bin is (mostly) there
    ldtCtrl = topRec[ldtBinName] ; -- The main LDT Control structure
    propMap = ldtCtrl[1];

    -- Extract the property map and Ldt control map from the Ldt bin list.
    if propMap[PM_Magic] ~= MAGIC or propMap[PM_LdtType] ~= ldtType then
      GP=E and warn("[ERROR EXIT]:<%s:%s>LDT BIN(%s) Corrupted (no magic)",
            MOD, meth, tostring( ldtBinName ) );
      error( ldte.ERR_BIN_DAMAGED );
    end
    -- Ok -- all done for the Must Exist case.
  else
    -- OTHERWISE, we're just checking that nothing looks bad, but nothing
    -- is REQUIRED to be there.  Basically, if a control bin DOES exist
    -- then it MUST have magic.
    if ( topRec and topRec[ldtBinName] ) then
      ldtCtrl = topRec[ldtBinName]; -- The main LdtMap structure
      propMap = ldtCtrl[1];
      if propMap and propMap[PM_Magic] ~= MAGIC then
        GP=E and warn("[ERROR EXIT]:<%s:%s> LDT BIN(%s) Corrupted (no magic)",
              MOD, meth, tostring( ldtBinName ) );
        error( ldte.ERR_BIN_DAMAGED );
      end
    end -- if worth checking
  end -- else for must exist

  -- Finally -- let's check the version of our code against the version
  -- in the data.  If there's a mismatch, then kick out with an error.
  -- Although, we check this in the "must exist" case, or if there's 
  -- a valid propMap to look into.
  if ( mustExist or propMap ) then
    local dataVersion = propMap[PM_Version];
    if ( not dataVersion or type(dataVersion) ~= "number" ) then
      dataVersion = 0; -- Basically signals corruption
    end

    if( codeVersion > dataVersion ) then
      warn("[ERROR EXIT]<%s:%s> Code Version (%d) <> Data Version(%d)",
        MOD, meth, codeVersion, dataVersion );
      warn("[Please reload data:: Automatic Data Upgrade not yet available");
      error( ldte.ERR_VERSION_MISMATCH );
    end
  end -- final version check

  GP=E and trace("[EXIT]<%s:%s> OK", MOD, meth);
  return ldtCtrl; -- Save the caller the effort of extracting the map.
end -- ldt_common.validateRecBinAndMap()

-- ======================================================================
-- Summarize the List (usually ResultList) so that we don't create
-- huge amounts of crap in the console.
-- Show Size, First Element, Last Element
-- ======================================================================
function ldt_common.summarizeList( myList )
  if( myList == nil ) then return "NULL LIST"; end;

  local resultMap = map();
  resultMap.Summary = "Summary of the List";
  local listSize  = list.size( myList );
  resultMap.ListSize = listSize;
  if resultMap.ListSize == 0 then
    resultMap.ListStatus = "List Is Empty";
  else
    resultMap.FirstElement = tostring( myList[1] );
    resultMap.LastElement =  tostring( myList[ listSize ] );
  end

  return tostring( resultMap );
end -- summarizeList()


-- ======================================================================
-- Dump the List (usually ResultList) with multiple prints so that we
-- can see the whole thing (regular Logging limits each print to something
-- like 1k or 2k per info/trace line).
-- ======================================================================
function ldt_common.dumpList( myList )
  if( myList == nil ) then
     info("NULL LIST");
     return;
  end

  -- Iterate thru the list (myList) and print items out 10 (or so) at a time.
  local subSize = 10;
  local count = 0;
  local remainderList = myList;
  local takeSize;
  local frontList;
  while ( list.size( remainderList ) > 0 ) do
    if( list.size( remainderList ) > subSize ) then
      takeSize = subSize;
    else
      takeSize = list.size( remainderList );
    end
    frontList = list.take( remainderList, takeSize );
    info("\n<LIST:[%d : %d] %s", count, count + takeSize, tostring(frontList));
    remainderList = list.drop( remainderList, takeSize );
  end

end -- ldt_common.dumpList()


-- ======================================================================
-- Summarize the MAP (usually ResultMap) so that we don't create
-- huge amounts of crap in the console.
-- Show Size and two Name/Values.  Unlike Summarize List, we really can't
-- make much sense of "first and last" items.
-- ======================================================================
function ldt_common.summarizeMap( myMap )
  if( myMap == nil ) then return "NULL MAP"; end;

  local resultMap = map();
  local summaryMap = map;
  resultMap.Summary = "Summary of the MAP";
  local mapSize  = map.size( myMap );
  resultMap.MapSize = mapSize;
  if resultMap.MapSize == 0 then
    resultMap.MapStatus = "Map Is Empty";
  else
    local limit = 5;
    for name, value in map.pairs( myMap ) do
      summaryMap[name] = value;
      limit = limit - 1;
      if( limit < 1 ) then
        resultMap.Summary = summaryMap;
      end
    end
  end

  return tostring( resultMap );
end -- summarizeMap()


-- ======================================================================
-- Dump the MAP (usually ResultMAP) with multiple prints so that we
-- can see the whole thing (regular Logging limits each print to something
-- like 1k or 2k per info/trace line).
-- ======================================================================
function ldt_common.dumpMap( myMap, msg )
  if( myMap == nil ) then
     info("NULL MAP");
     return;
  end

  info("\n <<<<> DUMP MAP [%s]<>>>>", tostring(msg));

  -- Iterate thru the map (myMap) and print items out 10 (or so) at a time.
  local subSize = 10;
  local count = 0;
  local subCount = 0;
  local subMap = map();
  for name, value in map.pairs( myMap ) do
    subMap[name] = value;
    subCount = subCount + 1;
    count = count + 1;
    if( subCount > subSize ) then
      info("\nSubMap[%d:%d] Map(%s)", count-subCount, count, tostring(subMap));
      subMap = map(); -- start a new map for the next round.
      subCount = 0;
    end
  end
  -- Print anything remaining -- after we fall out of the for loop.
  if( map.size( subMap ) ) then
      info("\nSubMap[%d:%d] Map(%s)", count-subCount, count, tostring(subMap));
  end
  info("\n<>>>>> END OF MAP <<<<>");

end -- ldt_common.dumpMap()


-- ======================================================================
-- ldt_common.listInsert()
-- ======================================================================
-- General List Insert function that can be used to insert
-- keys, digests or objects.
-- Return:
-- Success: 0
-- Error: Error String
-- ======================================================================
function ldt_common.listInsert( valList, newValue, position )
  local meth = "ldt_common.listInsert()";
  GP=F and trace("[ENTER]<%s:%s>List(%s) size(%d) Value(%s) Position(%d)", MOD,
  meth, tostring(valList), list.size(valList), tostring(newValue), position );

  local listSize = list.size( valList );
  if ( listSize == 0 or position > listSize or position == 0 ) then
    -- Just append to the list
    list.append( valList, newValue );
    GP=F and trace("[LIST APPEND]<%s:%s> Appended item(%s) to list(%s)",
      MOD, meth, tostring(newValue), tostring(valList) );
  else
    -- Move elements in the list from "Position" to the end (end + 1)
    -- and then insert the new value at "Position".  We go back to front so
    -- that we don't overwrite anything.
    -- (move pos:end to the right one cell)
    -- This example: Position = 1, end = 3. (1 based array indexing, not zero)
    --          +---+---+---+
    -- (111) -> |222|333|444| +----Cell added by list.append()
    --          +---+---+---+ V
    --          +---+---+---+---+
    -- (111) -> |   |222|333|444|
    --          +---+---+---+---+
    --          +---+---+---+---+
    --          |111|222|333|444|
    --          +---+---+---+---+
    -- Note that we can't index beyond the end, so that first move must be
    -- an append, not an index access list[end+1] = value.
    GP=F and trace("[LIST TRANSFER]<%s:%s> listSize(%d) position(%d)",
      MOD, meth, listSize, position );
    local endValue = valList[listSize];
    list.append( valList, endValue );
    for i = (listSize - 1), position, -1  do
      valList[i+1] = valList[i];
    end -- for()
    valList[position] = newValue;
  end

  GP=F and trace("[EXIT]<%s:%s> Appended(%s) to list(%s)", MOD, meth,
    tostring(newValue), tostring(valList));

  return 0;
end -- ldt_common.listInsert()

-- ======================================================================
-- ldt_common.listDelete()
-- ======================================================================
-- General List Delete function for removing a SINGLE ITEM from a list.
-- RETURN:
-- A NEW LIST that no longer includes the deleted item.
-- ======================================================================
function ldt_common.listDelete( objectList, position )
  local meth = "listDelete()";
  local resultList;
  local listSize = list.size( objectList );

  GP=F and trace("[ENTER]<%s:%s>List(%s) size(%d) Position(%s)", MOD,
  meth, tostring(objectList), listSize, tostring(position) );

  if( position < 1 or position > listSize ) then
    warn("[DELETE ERROR]<%s:%s> Bad position(%d) for delete.",
      MOD, meth, position );
    error( ldte.ERR_DELETE );
  end

  -- Move elements in the list to "cover" the item at Position.
  --  +---+---+---+---+
  --  |111|222|333|444|   Delete item (333) at position 3.
  --  +---+---+---+---+
  --  Moving forward, Iterate:  list[pos] = list[pos+1]
  --  This is what you would THINK would work:
  -- for i = position, (listSize - 1), 1 do
  --   objectList[i] = objectList[i+1];
  -- end -- for()
  -- objectList[i+1] = nil;  (or, call trim() )
  -- However, because we cannot assign "nil" to a list, nor can we just trim
  -- a list (not yet anyway), we have to build a NEW list from the old list,
  -- that contains JUST the pieces we want.
  --
  -- So, basically, we're going to build a new list out of the LEFT and
  -- RIGHT pieces of the original list.
  --
  -- Future work:  Swap the current item with the end, and then just take
  -- the list, minus the end.  This might perform better that doing two
  -- list operations.
  --
  -- Our List operators :
  -- (*) list.take (take the first N elements) 
  -- (*) list.drop (drop the first N elements, and keep the rest) 
  -- The special cases are:
  -- (*) A list of size 1:  Just return a new (empty) list.
  -- (*) We're deleting the FIRST element, so just use RIGHT LIST.
  -- (*) We're deleting the LAST element, so just use LEFT LIST
  if( listSize == 1 ) then
    resultList = list();
  elseif( position == 1 ) then
    resultList = list.drop( objectList, 1 );
  elseif( position == listSize ) then
    resultList = list.take( objectList, position - 1 );
  else
    resultList = list.take( objectList, position - 1);
    local addList = list.drop( objectList, position );
    local addLength = list.size( addList );
    for i = 1, addLength, 1 do
      list.append( resultList, addList[i] );
    end
  end

  GP=F and trace("[EXIT]<%s:%s>List(%s)", MOD, meth, tostring(resultList));
  return resultList;
end -- ldt_common.listDelete()

-- ======================================================================
-- ldt_common.listDeleteMultiple()
-- ======================================================================
-- General List Delete function for removing MULTIPLE items from a list.
-- Parms:
-- (*) objectList: the original list of items
-- (*) startPos: The Starting index of the item(s) we're deleting
-- (*) endPos: The ending index of the item(s) we're deleting.
-- RETURN:
-- A NEW LIST that no longer includes the deleted items.
--
-- ======================================================================
function ldt_common.listDeleteMultiple( objectList, startPos, endPos )
  local meth = "listDeleteMultiple()";
  local resultList;
  local listSize = list.size( objectList );

  GP=F and trace("[ENTER]<%s:%s>List(%s) size(%d) S Pos(%d) E Pos(%d)", MOD,
  meth, tostring(objectList), listSize, startPos, endPos );

  if( startPos < 1 or endPos > listSize or startPos > endPos) then
    warn("[DELETE ERROR]<%s:%s> Bad positions: Start(%d) End(%d)for delete.",
      MOD, meth, startPos, endPos );
    error( ldte.ERR_DELETE );
  end

  -- Move elements in the list to "cover" the items that are at the range
  -- of "startPos to endPos.  This has to work for all cases:
  -- (*) The entire list
  -- (*) Only One item (start == end)  (including start or end)
  -- (*) Any Range in the middle
  --  +---+---+---+---+---+---+---+---+
  --  |111|222|333|444|555|666|777|888|  Delete items from Pos 3 to 5
  --  +---+---+---+---+---+---+---+---+
  --     1   2   3   4   5   6   7   8 (indexes -- Lua starts at 1, not 0)
  
  -- We're going to build a new list out of the LEFT and
  -- RIGHT pieces of the original list.
  --
  -- Our List operators :
  -- (*) list.take (take the first N elements) 
  -- (*) list.drop (drop the first N elements, and keep the rest) 
  -- The special cases are:
  -- (*) A list of size 1:  Just return a new (empty) list.
  -- (*) We're deleting the FIRST element, so just use RIGHT LIST.
  -- (*) We're deleting the LAST element, so just use LEFT LIST
  if( listSize == 1 or (startPos == 1 and endPos == listSize)) then
    -- We are deleting everything -- just get a new empty list.
    resultList = list();
  elseif( startPos == 1 ) then
    -- There is no front section -- just create a list of the elements tht
    -- are beyong the end of endPos.
    resultList = list.drop( objectList, endPos );
  elseif( endPos == listSize ) then
    -- There is no back section -- just take the front part.
    resultList = list.take( objectList, startPos - 1 );
  else
    -- Remove the middle section -- take the front part and then
    -- append the back part.
    resultList = list.take( objectList, startPos - 1);
    local addList = list.drop( objectList, endPos );
    local addLength = list.size( addList );
    for i = 1, addLength, 1 do
      list.append( resultList, addList[i] );
    end
  end

  GP=F and trace("[EXIT]<%s:%s>List(%s)", MOD, meth, tostring(resultList));
  return resultList;
end -- ldt_common.listDeleteMultiple()

-- =======================================================================
-- searchOrderedList()
-- =======================================================================
-- Search an Ordered list for an item.  This is the simple Linear Search method.
--
-- (*) valList: the list of Values from the record bin
-- (*) searchKey: the "value"  we're searching for
-- Return A,B:
-- A: Return the position if found, else return ZERO.
-- B: The Correct position to insert, if not found (the index of where
--    this value will go, and all current values will shift to the right.
-- Recall the Lua Arrays start with index ONE (not zero)
-- =======================================================================
local function searchOrderedList( valList, searchKey )
    local meth = "searchOrderedList()";
    GP=F and trace("[ENTER]: <%s:%s> Looking for searchKey(%s) in List(%s)",
        MOD, meth, tostring(searchKey), tostring(valList));

    local foundPos = 0;
    local insertPos = 0;

    -- Nothing to search if the list is null or empty
    if( valList == nil or list.size( valList ) == 0 ) then
        GP=F and trace("[DEBUG]<%s:%s> EmptyList", MOD, meth );
        return 0,0;
    end

    -- Search the list for the item (searchKey) return the position if found.
    -- Note that searchKey may be the entire object, or it may be a subset.
    local listSize = list.size(valList);
    local item;
    local dbKey;
    for i = 1, listSize, 1 do
        item = valList[i];
        GP=F and trace("[COMPARE]<%s:%s> index(%d) SV(%s) and ListVal(%s)",
            MOD, meth, i, tostring(searchKey), tostring(item));
        -- a value that does not exist, will have a nil valList item
        -- so we'll skip this if-loop for it completely                  
        if item ~= nil and item == searchKey then
            foundPos = i;
            break;
        elseif searchKey < item and insertPos == 0 then
            insertPos = i;
            break;
        end -- end if not null and equals
    end -- end for each item in the list

    GP=F and trace("[EXIT]<%s:%s> Result: FindPos(%d) InsertPos(%d)",
        MOD, meth, foundPos, insertPos );
    return foundPos, insertPos;
end -- searchOrderedList()

-- =======================================================================
-- ldt_common.binSearchOrderedList()
-- =======================================================================
-- Search the ordered list, using binary search, for the given value.
-- Parms:
-- (*) valueList:
-- (*) key:
-- (*) compFunc: The Compare Function
-- (*) reversed: True when order is descending
-- If the  value is found:
-- it returns a table holding all the matching indices
-- (e.g. { startindice,endindice } )
-- Note that endindice may be the same as startindice if only one
-- matching indice was found
-- If compFunc is given:
-- then it must be a function that takes one value and returns a second value2,
-- to be compared with the input value, e.g.:
-- compvalue = function( value ) return value[1] end
-- If reversed is set to true:
-- then the search assumes that the table is sorted in reverse order
-- (largest value at position 1).
-- Note when reversed is given compval must be given as well, it can be
-- nil/_ in this case
-- Return:
-- SUCCESS: a table holding matching indices
-- (e.g. { startindice,endindice } )
-- FAILURE: nil
-- =======================================================================
-- Avoid heap allocs for performance
local default_fcompval = function( value ) return value end
local fcompf = function( a,b ) return a < b end
local fcompr = function( a,b ) return a > b end
local function binsearch( t,value,fcompval,reversed )
    -- Initialise functions
    local fcompval = fcompval or default_fcompval
    local fcomp = reversed and fcompr or fcompf
    --  Initialise numbers
    local iStart,iEnd,iMid = 1,#t,0
    -- Binary Search
    while iStart <= iEnd do
        -- calculate middle
        iMid = math.floor( (iStart+iEnd)/2 )
        -- get compare value
        local value2 = fcompval( t[iMid] )
        -- get all values that match
        if value == value2 then
            local tfound,num = { iMid,iMid },iMid - 1
            while value == fcompval( t[num] ) do
                tfound[1],num = num,num - 1
            end
            num = iMid + 1
            while value == fcompval( t[num] ) do
                tfound[2],num = num,num + 1
            end
            return tfound
            -- keep searching
        elseif fcomp( value,value2 ) then
            iEnd = iMid - 1
        else
            iStart = iMid + 1
        end
    end
end


-- =======================================================================
-- table.bininsert( table, value [, comp] )
--
-- Inserts a given value through BinaryInsert into the table sorted
-- by [, comp].
--
-- If 'comp' is given, then it must be a function that receives
-- two table elements, and returns true when the first is less
-- than the second, e.g. comp = function(a, b) return a > b end,
-- will give a sorted table, with the biggest value on position 1.
-- [, comp] behaves as in table.sort(table, value [, comp])
-- returns the index where 'value' was inserted
-- =======================================================================
-- Avoid heap allocs for performance
local fcomp_default = function( a,b ) return a < b end
local function bininsert(t, value, fcomp)
    -- Initialise compare function
    local fcomp = fcomp or fcomp_default
    --  Initialise numbers
    local iStart,iEnd,iMid,iState = 1,#t,1,0
    -- Get insert position
    while iStart <= iEnd do
        -- calculate middle
        iMid = math.floor( (iStart+iEnd)/2 )
        -- compare
        if fcomp( value,t[iMid] ) then
            iEnd,iState = iMid - 1,0
        else
            iStart,iState = iMid + 1,1
        end
    end
    table.insert( t,(iMid+iState),value )
    return (iMid+iState)
end

-- =========================================================================
-- ldt_common.validateList()
-- =========================================================================
-- validate that the list passed in is in sorted order, with no duplicates
-- =========================================================================
function ldt_common.validateList( valList )
    local result = true;

    if( valList == nil ) then
        return false;
    end

    local listSize = list.size(valList);
    for i = 1, ( listSize - 1), 1 do
        if( valList[i] == nil or valList[i+1] == nil ) then
            return false;
        end
        if( valList[i] >= valList[i+1] == nil ) then
            return false;
        end
    end
    return true;
end -- ldt_common.validateList()


-- =========================================================================
-- ldt_common.validateCodeAndData()
-- =========================================================================
-- va
-- =========================================================================
function ldt_common.validateCodeAndData( codeVersion, dataVersion )

  -- Code versions must be valid
  if not ( codeVersion and dataVersion ) then
    warn("[INTERNAL ERROR: Version Data corrupted");
    error( ldte.ERR_INTERNAL );
  end

  if not ( codeVersion > dataVersion ) then
    warn("[INTERNAL ERROR: Code and Data Mismatch. Please reload data.");
    info("Automatic Data Upgrade not yet enabled");
    error( ldte.ERR_INTERNAL );
  end
end

-- =======================================================================
ldt_common.FirstNames = {"Kunta", "Bob", "Kevin"}
ldt_common.LastNames = {"Kinte", "Anderson", "Johnson"}

-- =======================================================================
-- createPersonObject( flavor, skew )
-- =======================================================================
-- Create a Person Object that will be used in testing LDTs, especially
-- filters, key functions, unique_value functions and compression functions.
--
-- Note that only FirstName, and LastName are required.
-- 
-- "FirstName": User First Name (String)
-- "LastName": User Last Name (String)
-- "DOB": User data of birth (String)
-- "SSNum": User social security number (Number)
-- "HomeAddr": User Home Address (String)
-- "HomePhone": User Home Phone Number (Number)
-- "CellPhone": User Cell Phone Number (Number)
-- "DL": User Driver's License number (String)
-- "UserPref": User Preferences (Map)
-- "UserCom": User Comments (List)
-- "Hobbies": User Hobbies (list)
-- 
-- The algorithm used here to create relatively unique values is to take
-- various factors  of the input parameters to extract names from lists.
--
-- Parms:
-- (*) flavor: Picks the main type of object
-- (*) skew:   Used to offset the main type and inject different details
-- Return:
-- a Map containing interesting values
-- -- =======================================================================
function ldt_common.createPersonObject( flavor, skew )
    local meth = "createPersonObject()";
    GP=F and trace("[ENTER]: <%s:%s> flavor(%s) skew(%s) ", MOD, meth,
      tostring(flavor), tostring(skew));

    local newObject = map();
    local flavorIndex = (flavor % 3) + 1;
    local skewIndex = ((flavor * 2 + skew) % 3) + 1;
    newObject.FirstName = ldt_common.FirstNames[flavorIndex];
    newObject.LastName = ldt_common.LastNames[skewIndex];
    newObject.DOB = "03/27/1950";
    newObject.SSNum = 123456789;
    newObject.HomeAddr = "17 West Cherry Tree Lane";
    newObject.HomePhone = "(408) 555-3549";
    newObject.CellPhone = "(408) 555-2063";
    newObject.DL = "C6988872";
    newObject.UserPref = "Standard";
    newObject.UserCom = {"Good Documentation", "Needs better examples"};
    newObject.Hobbies = {"Tennis", "Golf", "Game of Thrones", "Volleyball"};

    GP=F and trace("[EXIT]<%s:%s> Result Object(%s)", MOD, meth,
      tostring(newObject));
  return newObject;
end

-- ========================================================================
-- Return the ldt_commonm MAP (or table) that contains all of the functions
-- that we're exporting from this module.
-- ========================================================================
return ldt_common;

-- ========================================================================
--  _     ____ _____    ____                                      
-- | |   |  _ |_   _|  / ___|___  _ __ ___  _ __ ___   ___  _ __  
-- | |   | | | || |   | |   / _ \| '_ ` _ \| '_ ` _ \ / _ \| '_ \ 
-- | |___| |_| || |   | |__| (_) | | | | | | | | | | | (_) | | | |
-- |_____|____/ |_|    \____\___/|_| |_| |_|_| |_| |_|\___/|_| |_| (LIB)
--
-- ========================================================================
-- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> --
