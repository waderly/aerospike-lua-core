-- Large Ordered List (llist.lua)
--
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

-- Track the date and iteration of the last update:
local MOD = "lib_llist_2014_07_01.A";

-- This variable holds the version of the code. It should match the
-- stored version (the version of the code that stored the ldtCtrl object).
-- If there's a mismatch, then some sort of upgrade is needed.
-- This number is currently an integer because that is all that we can
-- store persistently.  Ideally, we would store (Major.Minor), but that
-- will have to wait until later when the ability to store real numbers
-- is eventually added.
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
local E=false; -- Set F (flag) to true to turn ON Enter/Exit print
local B=false; -- Set B (Banners) to true to turn ON Banner Print
local D=false; -- Set D (Detail) to get more Detailed Debug Output.
local GD;      -- Global Debug instrument.
local DEBUG=false; -- turn on for more elaborate state dumps.

-- ======================================================================
-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- Large List (LLIST) Library Functions
-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- ======================================================================
-- (*) Status = llist.add(topRec, ldtBinName, newValue, userModule, src)
-- (*) Status = llist.add_all(topRec, ldtBinName, valueList, userModule, src)
-- (*) List   = llist.find(topRec,ldtBinName,key,userModule,filter,fargs, src)
-- (*) Object = llist.find_min(topRec,ldtBinName, src)
-- (*) Object = llist.find_max(topRec,ldtBinName, src)
-- (*) List   = llist.take(topRec,ldtBinName,key,userModule,filter,fargs, src)
-- (*) Object = llist.take_min(topRec,ldtBinName, src)
-- (*) Object = llist.take_max(topRec,ldtBinName, src)
-- (*) List   = llist.scan(topRec, ldtBinName, userModule, filter, fargs, src)
-- (*) Status = llist.update(topRec, ldtBinName, userObject, src)
-- (*) Status = llist.remove(topRec, ldtBinName, searchValue  src) 
-- (*) Status = llist.destroy(topRec, ldtBinName, src)
-- (*) Number = llist.size(topRec, ldtBinName )
-- (*) Map    = llist.get_config(topRec, ldtBinName )
-- (*) Status = llist.set_capacity(topRec, ldtBinName, new_capacity)
-- (*) Status = llist.get_capacity(topRec, ldtBinName )
-- ======================================================================
-- Large List Design/Architecture
--
-- The Large Ordered List is a sorted list, organized according to a Key
-- value.  It is assumed that the stored object is more complex than just an
-- atomic key value -- otherwise one of the other Large Object mechanisms
-- (e.g. Large Stack, Large Set) would be used.  The cannonical form of a
-- LLIST object is a map, which includes a KEY field and other data fields.
--
-- In this first version, we may choose to use a FUNCTION to derrive the 
-- key value from the complex object (e.g. Map).
-- In the first iteration, we will use atomic values and the fixed KEY field
-- for comparisons.
--
-- Compared to Large Stack and Large Set, the Large Ordered List is managed
-- continuously (i.e. it is kept sorted), so there is some additional
-- overhead in the storage operation (to do the insertion sort), but there
-- is reduced overhead for the retieval operation, since it is doing a
-- binary search (order log(N)) rather than scan (order N).
-- ======================================================================
-- >> Please refer to ldt/doc_llist.md for architecture and design notes.
-- ======================================================================

-- ======================================================================
-- Aerospike Database Server Functions:
-- ======================================================================
-- Aerospike Record Functions:
-- status = aerospike:create( topRec )
-- status = aerospike:update( topRec )
-- status = aerospike:remove( topRec ) (not currently used)
--
-- Aerospike SubRecord Functions:
-- newRec = aerospike:create_subrec( topRec )
-- rec    = aerospike:open_subrec( topRec, digestString )
-- status = aerospike:update_subrec( childRec )
-- status = aerospike:close_subrec( childRec )
-- status = aerospike:remove_subrec( subRec ) 
--
-- Record Functions:
-- digest = record.digest( childRec )
-- status = record.set_type( topRec, recType )
-- status = record.set_flags( topRec, ldtBinName, binFlags )
-- ======================================================================

-- ======================================================================
-- FORWARD Function DECLARATIONS
-- ======================================================================
-- We have some circular (recursive) function calls, so to make that work
-- we have to predeclare some of them here (they look like local variables)
-- and then later assign the function body to them.
-- ======================================================================
local insertParentNode;

-- ++==================++
-- || External Modules ||
-- ++==================++
-- Set up our "outside" links.
-- Get addressability to the Function Table: Used for compress/transform,
-- keyExtract, Filters, etc. 
local functionTable = require('ldt/UdfFunctionTable');

-- When we're ready, we'll move all of our common routines into ldt_common,
-- which will help code maintenance and management.
-- local LDTC = require('ldt/ldt_common');

-- We import all of our error codes from "ldt_errors.lua" and we access
-- them by prefixing them with "ldte.XXXX", so for example, an internal error
-- return looks like this:
-- error( ldte.ERR_INTERNAL );
local ldte = require('ldt/ldt_errors');

-- We have a set of packaged settings for each LDT
local llistPackage = require('ldt/settings_llist');

-- We have recently moved a number of COMMON functions into the "ldt_common"
-- module, namely the subrec routines and some list management routines.
-- We will likely move some other functions in there as they become common.
local ldt_common = require('ldt/ldt_common');

-- |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- || FUNCTION TABLE ||
-- |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- Table of Functions: Used for Transformation and Filter Functions.
-- This is held in UdfFunctionTable.lua.  Look there for details.
-- ===========================================
-- || GLOBAL VALUES -- Local to this module ||
-- ===========================================
-- ++====================++
-- || INTERNAL BIN NAMES || -- Local, but global to this module
-- ++====================++
-- The Top Rec LDT bin is named by the user -- so there's no hardcoded name
-- for each used LDT bin.
--
-- In the main record, there is one special hardcoded bin -- that holds
-- some shared information for all LDTs.
-- Note the 14 character limit on Aerospike Bin Names.
-- >> (14 char name limit) >>12345678901234<<<<<<<<<<<<<<<<<<<<<<<<<
local REC_LDT_CTRL_BIN    = "LDTCONTROLBIN"; -- Single bin for all LDT in rec

-- There are THREE different types of (Child) subrecords that are associated
-- with an LLIST LDT:
-- (1) Internal Node Subrecord:: Internal nodes of the B+ Tree
-- (2) Leaf Node Subrecords:: Leaf Nodes of the B+ Tree
-- (3) Existence Sub Record (ESR) -- Ties all children to a parent LDT
-- Each Subrecord has some specific hardcoded names that are used
--
-- All LDT subrecords have a properties bin that holds a map that defines
-- the specifics of the record and the LDT.
-- NOTE: Even the TopRec has a property map -- but it's stashed in the
-- user-named LDT Bin
-- >> (14 char name limit) >>12345678901234<<<<<<<<<<<<<<<<<<<<<<<<<
local SUBREC_PROP_BIN     = "SR_PROP_BIN";
--
-- The Node SubRecords (NSRs) use the following bins:
-- The SUBREC_PROP_BIN mentioned above, plus 3 of 4 bins
-- >> (14 char name limit) >>12345678901234<<<<<<<<<<<<<<<<<<<<<<<<<
local NSR_CTRL_BIN        = "NsrControlBin";
local NSR_KEY_LIST_BIN    = "NsrKeyListBin"; -- For Var Length Keys
local NSR_KEY_BINARY_BIN  = "NsrBinaryBin";-- For Fixed Length Keys
local NSR_DIGEST_BIN      = "NsrDigestBin"; -- Digest List

-- The Leaf SubRecords (LSRs) use the following bins:
-- The SUBREC_PROP_BIN mentioned above, plus
-- >> (14 char name limit) >>12345678901234<<<<<<<<<<<<<<<<<<<<<<<<<
local LSR_CTRL_BIN        = "LsrControlBin";
local LSR_LIST_BIN        = "LsrListBin";
local LSR_BINARY_BIN      = "LsrBinaryBin";

-- The Existence Sub-Records (ESRs) use the following bins:
-- The SUBREC_PROP_BIN mentioned above (and that might be all)

-- ++==================++
-- || GLOBAL CONSTANTS ||
-- ++==================++
-- Each LDT defines its type in string form.
local LDT_TYPE = "LLIST";

-- For Map objects, we may look for a special KEY FIELD
local KEY_FIELD  = "key";

-- Switch from a single list to B+ Tree after this amount
local DEFAULT_THRESHOLD = 100;

-- Use this to test for LdtMap Integrity.  Every map should have one.
local MAGIC="MAGIC";     -- the magic value for Testing LLIST integrity

-- AS_BOOLEAN TYPE:
-- There are apparently either storage or conversion problems with booleans
-- and Lua and Aerospike, so rather than STORE a Lua Boolean value in the
-- LDT Control map, we're instead going to store an AS_BOOLEAN value, which
-- is a character (defined here).  We're using Characters rather than
-- numbers (0, 1) because a character takes ONE byte and a number takes EIGHT
local AS_TRUE='T';
local AS_FALSE='F';

-- StoreMode (SM) values (which storage Mode are we using?)
local SM_BINARY  ='B'; -- Using a Transform function to compact values
local SM_LIST    ='L'; -- Using regular "list" mode for storing values.

-- StoreState (SS) values (which "state" is the set in?)
local SS_COMPACT ='C'; -- Using "single bin" (compact) mode
local SS_REGULAR ='R'; -- Using "Regular Storage" (regular) mode

-- KeyType (KT) values
local KT_ATOMIC  ='A'; -- the set value is just atomic (number or string)
local KT_COMPLEX ='C'; -- the set value is complex. Use Function to get key.

-- KeyDataType (KDT) value
local KDT_NUMBER = 'N'; -- The key (or derived key) is a NUMBER
local KDT_STRING = 'S'; -- The key (or derived key) is a STRING

-- Search Constants:: Use Numbers so that it translates to C
local ST_FOUND    =  0;
local ST_NOTFOUND = -1;

-- Values used in Compare (CR = Compare Results)
local CR_LESS_THAN      = -1;
local CR_EQUAL          =  0;
local CR_GREATER_THAN   =  1;
local CR_ERROR          = -2;
local CR_INTERNAL_ERROR = -3;

-- Errors used in LDT Land
local ERR_OK            =  0; -- HEY HEY!!  Success
local ERR_GENERAL       = -1; -- General Error
local ERR_NOT_FOUND     = -2; -- Search Error

-- Scan Status:  Do we keep scanning, or stop?
local SCAN_ERROR        = -1;  -- Error during Scanning
local SCAN_DONE         =  0;  -- Done scanning
local SCAN_CONINTUE     =  1;  -- Keep Scanning

-- Record Types -- Must be numbers, even though we are eventually passing
-- in just a "char" (and int8_t).
-- NOTE: We are using these vars for TWO purposes -- and I hope that doesn't
-- come back to bite me.
-- (1) As a flag in record.set_type() -- where the index bits need to show
--     the TYPE of record (RT_LEAF NOT used in this context)
-- (2) As a TYPE in our own propMap[PM_RecType] field: CDIR *IS* used here.
local RT_REG  = 0; -- 0x0: Regular Record (Here only for completeneness)
local RT_LDT  = 1; -- 0x1: Top Record (contains an LDT)
local RT_NODE = 2; -- 0x2: Regular Sub Record (Node, Leaf)
local RT_SUB  = 2; -- 0x2: Regular Sub Record (Node, Leaf)::Used for set_type
local RT_LEAF = 3; -- xxx: Leaf Nodes:: Not used for set_type() 
local RT_ESR  = 4; -- 0x4: Existence Sub Record

-- Bin Flag Types -- to show the various types of bins.
-- NOTE: All bins will be labelled as either (1:RESTRICTED OR 2:HIDDEN)
-- We will not currently be using "Control" -- that is effectively HIDDEN
local BF_LDT_BIN     = 1; -- Main LDT Bin (Restricted)
local BF_LDT_HIDDEN  = 2; -- LDT Bin::Set the Hidden Flag on this bin
local BF_LDT_CONTROL = 4; -- Main LDT Control Bin (one per record)

-- We maintain a pool, or "context", of subrecords that are open.  That allows
-- us to look up subrecs and get the open reference, rather than bothering
-- the lower level infrastructure.  There's also a limit to the number
-- of open subrecs.
local G_OPEN_SR_LIMIT = 20;

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
local PM_ItemCount             = 'I'; -- (Top): Count of all items in LDT
local PM_Version               = 'V'; -- (Top): Code Version
local PM_SubRecCount           = 'S'; -- (Top): # of subrecs in the LDT
local PM_LdtType               = 'T'; -- (Top): Type: stack, set, map, list
local PM_BinName               = 'B'; -- (Top): LDT Bin Name
local PM_Magic                 = 'Z'; -- (All): Special Sauce
local PM_CreateTime            = 'C'; -- (All): Creation time of this rec
local PM_EsrDigest             = 'E'; -- (All): Digest of ESR
local PM_RecType               = 'R'; -- (All): Type of Rec:Top,Ldr,Esr,CDir
-- local PM_LogInfo               = 'L'; -- (All): Log Info (currently unused)
local PM_ParentDigest          = 'P'; -- (Subrec): Digest of TopRec
local PM_SelfDigest            = 'D'; -- (Subrec): Digest of THIS Record

-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
-- Leaf and Node Fields (There is some overlap between nodes and leaves)
-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
local LF_ListEntryCount       = 'L';-- # current list entries used
local LF_ListEntryTotal       = 'T';-- # total list entries allocated
local LF_ByteEntryCount       = 'B';-- # current bytes used
local LF_PrevPage             = 'P';-- Digest of Previous (left) Leaf Page
local LF_NextPage             = 'N';-- Digest of Next (right) Leaf Page

local ND_ListEntryCount       = 'L';-- # current list entries used
local ND_ListEntryTotal       = 'T';-- # total list entries allocated
local ND_ByteEntryCount       = 'B';-- # current bytes used

-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
-- Main LLIST LDT Record (root) Map Fields
-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
-- These Field Values must match ALL of the other LDTs
-- Note that the other LDTs use "M_xxx" values, and LLIST use "R_xxx"
-- values, but where they must be common, they will be all "M_xxx" values.
--
-- Fields Common to ALL LDTs (managed by the LDT COMMON routines)
local M_UserModule          = 'P';-- User's Lua file for overrides
local M_KeyFunction         = 'F';-- Function to compute Key from Object
local M_KeyType             = 'k';-- Type of key (atomic, complex)
local M_StoreMode           = 'M';-- SM_LIST or SM_BINARY (applies to all nodes)
local M_StoreLimit          = 'L';-- Storage Capacity Limit
local M_Transform           = 't';-- Transform Object (from User to bin store)
local M_UnTransform         = 'u';-- Reverse transform (from storage to user)
local M_OverWrite           = 'o';-- Allow Overwrite (AS_TRUE or AS_FALSE)

-- Tree Level values
local R_TotalCount          = 'T';-- A count of all "slots" used in LLIST
local R_LeafCount           = 'c';-- A count of all Leaf Nodes
local R_NodeCount           = 'C';-- A count of all Nodes (including Leaves)
local R_TreeLevel           = 'l';-- Tree Level (Root::Inner nodes::leaves)
local R_KeyDataType         = 'd';-- Data Type of key (Number, Integer)
local R_KeyUnique           = 'U';-- Are Keys Unique? (AS_TRUE or AS_FALSE))
local R_StoreState          = 'S';-- Compact or Regular Storage
local R_Threshold           = 'H';-- After this#:Move from compact to tree mode
-- Key and Object Sizes, when using fixed length (byte array stuff)
local R_KeyByteSize         = 'B';-- Fixed Size (in bytes) of Key
local R_ObjectByteSize      = 'b';-- Fixed Size (in bytes) of Object
-- Top Node Tree Root Directory
local R_RootListMax         = 'R'; -- Length of Key List (page list is KL + 1)
local R_RootByteCountMax    = 'r';-- Max # of BYTES for keyspace in the root
local R_KeyByteArray        = 'J'; -- Byte Array, when in compressed mode
local R_DigestByteArray     = 'j'; -- DigestArray, when in compressed mode
local R_RootKeyList         = 'K';-- Root Key List, when in List Mode
local R_RootDigestList      = 'D';-- Digest List, when in List Mode
local R_CompactList         = 'Q';--Simple Compact List -- before "tree mode"
-- LLIST Inner Node Settings
local R_NodeListMax         = 'X';-- Max # of items in a node (key+digest)
local R_NodeByteCountMax    = 'Y';-- Max # of BYTES for keyspace in a node
-- LLIST Tree Leaves (Data Pages)
local R_LeafListMax         = 'x';-- Max # of items in a leaf node
local R_LeafByteCountMax    = 'y';-- Max # of BYTES for obj space in a leaf
local R_LeftLeafDigest      = 'A';-- Record Ptr of Left-most leaf
local R_RightLeafDigest     = 'Z';-- Record Ptr of Right-most leaf
-- ------------------------------------------------------------------------
-- Maintain the Field letter Mapping here, so that we never have a name
-- collision: Obviously -- only one name can be associated with a character.
-- We won't need to do this for the smaller maps, as we can see by simple
-- inspection that we haven't reused a character.
-- ----------------------------------------------------------------------
-- >>> Be Mindful of the LDT Common Fields that ALL LDTs must share <<<
-- ----------------------------------------------------------------------
-- A:R_LeftLeafDigest         a:                        0:
-- B:R_KeyByteSize            b:R_NodeByteCountSize     1:
-- C:R_NodeCount              c:R_LeafCount             2:
-- D:R_RootDigestList         d:R_KeyDataType           3:
-- E:                         e:                        4:
-- F:M_KeyFunction            f:                        5:
-- G:                         g:                        6:
-- H:R_Threshold              h:                        7:
-- I:                         i:                        8:
-- J:R_KeyByteArray           j:R_DigestByteArray       9:
-- K:R_RootKeyList            k:M_KeyType         
-- L:                         l:R_TreeLevel          
-- M:M_StoreMode              m:                
-- N:                         n:
-- O:                         o:
-- P:M_UserModule             p:
-- Q:R_CompactList            q:R_LeafByteEntrySize
-- R:R_RootListMax            r:R_RootByteCountMax      
-- S:R_StoreState             s:                        
-- T:R_TotalCount             t:M_Transform
-- U:R_KeyUnique              u:M_UnTransform
-- V:                         v:
-- W:                         w:                        
-- X:R_NodeListMax            x:R_LeafListMax           
-- Y:R_NodeByteCountMax       y:R_LeafByteCountMax
-- Z:R_RightLeafDigest        z:
-- -- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
--
-- Key Compare Function for Complex Objects
-- By default, a complex object will have a "key" field (held in the KEY_FIELD
-- global constant) which the -- key_compare() function will use to compare.
-- If the user passes in something else, then we'll use THAT to perform the
-- compare, which MUST return -1, 0 or 1 for A < B, A == B, A > B.
-- UNLESS we are using a simple true/false equals compare.
-- ========================================================================
-- Actually -- the default will be EQUALS.  The >=< functions will be used
-- in the Ordered LIST implementation, not in the simple list implementation.
-- ========================================================================
local KC_DEFAULT="keyCompareEqual"; -- Key Compare used only in complex mode
local KH_DEFAULT="keyHash";         -- Key Hash used only in complex mode

-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- <><><><> <Initialize Control Maps> <Initialize Control Maps> <><><><>
-- There are three main Record Types used in the LLIST Package, and their
-- initialization functions follow.  The initialization functions
-- define the "type" of the control structure:
--
-- (*) TopRec: the top level user record that contains the LLIST bin,
--     including the Root Directory.
-- (*) InnerNodeRec: Interior B+ Tree nodes
-- (*) DataNodeRec: The Data Leaves
--
-- <+> Naming Conventions:
--   + All Field names (e.g. ldtMap[M_StoreMode]) begin with Upper Case
--   + All variable names (e.g. ldtMap[M_StoreMode]) begin with lower Case
--   + All Record Field access is done using brackets, with either a
--     variable or a constant (in single quotes).
--     (e.g. topRec[ldtBinName] or ldrRec['NodeCtrlBin']);

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
local G_Filter = nil;
local G_Transform = nil;
local G_UnTransform = nil;
local G_FunctionArgs = nil;
local G_KeyFunction = nil;

-- Special Function -- if supplied by the user in the "userModule", then
-- we call that UDF to adjust the LDT configuration settings.
local G_SETTINGS = "adjust_settings";

-- <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> 
-- -----------------------------------------------------------------------
-- resetPtrs()
-- -----------------------------------------------------------------------
-- Reset the UDF Ptrs to nil.
-- -----------------------------------------------------------------------
local function resetUdfPtrs()
  G_Filter = nil;
  G_Transform = nil;
  G_UnTransform = nil;
  G_FunctionArgs = nil;
  G_KeyFunction = nil;
end -- resetPtrs()

-- <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> 
-- -----------------------------------------------------------------------
-- -----------------------------------------------------------------------
-- ======================================================================
-- <USER FUNCTIONS> - <USER FUNCTIONS> - <USER FUNCTIONS> - <USER FUNCTIONS>
-- ======================================================================

-- ======================================================================
-- propMapSummary( resultMap, propMap )
-- ======================================================================
-- Add the propMap properties to the supplied resultMap.
-- ======================================================================
local function propMapSummary( resultMap, propMap )

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

-- ======================================================================
-- ldtMapSummary( resultMap, ldtMap )
-- ======================================================================
-- Add the ldtMap properties to the supplied resultMap.
-- ======================================================================
local function ldtMapSummary( resultMap, ldtMap )

  -- General Tree Settings
  resultMap.StoreMode         = ldtMap[M_StoreMode];
  resultMap.StoreState        = ldtMap[R_StoreState];
  resultMap.StoreLimit        = ldtMap[M_StoreLimit];
  resultMap.TreeLevel         = ldtMap[R_TreeLevel];
  resultMap.LeafCount         = ldtMap[R_LeafCount];
  resultMap.NodeCount         = ldtMap[R_NodeCount];
  resultMap.KeyType           = ldtMap[M_KeyType];
  resultMap.TransFunc         = ldtMap[M_Transform];
  resultMap.UnTransFunc       = ldtMap[M_UnTransform];
  resultMap.KeyFunction       = ldtMap[M_KeyFunction];
  resultMap.UserModule        = ldtMap[M_UserModule];

  -- Top Node Tree Root Directory
  resultMap.RootListMax        = ldtMap[R_RootListMax];
  resultMap.KeyByteArray       = ldtMap[R_KeyByteArray];
  resultMap.DigestByteArray    = ldtMap[R_DigestByteArray];
  resultMap.KeyList            = ldtMap[R_KeyList];
  resultMap.DigestList         = ldtMap[R_DigestList];
  resultMap.CompactList        = ldtMap[R_CompactList];
  
  -- LLIST Inner Node Settings
  resultMap.InnerNodeEntryCountMax = ldtMap[R_InnerNodeEntryCountMax];
  resultMap.InnerNodeByteEntrySize = ldtMap[R_InnerNodeByteEntrySize];
  resultMap.InnerNodeByteCountMax  = ldtMap[R_InnerNodeByteCountMax];

  -- LLIST Tree Leaves (Data Pages)
  resultMap.DataPageEntryCountMax  = ldtMap[R_DataPageEntryCountMax];
  resultMap.DataPageByteEntrySize  = ldtMap[R_DataPageByteEntrySize];
  resultMap.DataPageByteCountMax   = ldtMap[R_DataPageByteCountMax];

end -- ldtMapSummary()

-- ======================================================================
-- local function Tree Summary( ldtCtrl ) (DEBUG/Trace Function)
-- ======================================================================
-- For easier debugging and tracing, we will summarize the Tree Map
-- contents -- without printing out the entire thing -- and return it
-- as a string that can be printed.
-- ======================================================================
local function ldtSummary( ldtCtrl )

  -- Extract the property map and control map from the ldt bin list.
  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];
  
  local resultMap             = map();
  resultMap.SUMMARY           = "LList Summary";

  -- General Properties (the Properties Bin
  propMapSummary( resultMap, propMap );

  -- General Tree Settings
  -- Top Node Tree Root Directory
  -- LLIST Inner Node Settings
  -- LLIST Tree Leaves (Data Pages)
  ldtMapSummary( resultMap, ldtMap );

  return  resultMap;
end -- ldtSummary()

-- ======================================================================
-- Do the summary of the LDT, and stringify it for internal use.
-- ======================================================================
local function ldtSummaryString( ldtCtrl )
  return tostring( ldtSummary( ldtCtrl ) );
end -- ldtSummaryString()

-- ======================================================================
-- ldtDebugDump()
-- ======================================================================
-- To aid in debugging, dump the entire contents of the ldtCtrl object
-- for LMAP.  Note that this must be done in several prints, as the
-- information is too big for a single print (it gets truncated).
-- ======================================================================
local function ldtDebugDump( ldtCtrl )
  info("\n\n <><><><><><><><><> [ LDT LLIST SUMMARY ] <><><><><><><><><> \n");

  -- Print MOST of the "TopRecord" contents of this LLIST object.
  local resultMap                = map();
  resultMap.SUMMARY              = "LLIST Summary";

  if ( ldtCtrl == nil ) then
    warn("[ERROR]: <%s:%s>: EMPTY LDT BIN VALUE", MOD, meth);
    resultMap.ERROR =  "EMPTY LDT BIN VALUE";
    info("<<<%s>>>", tostring(resultMap));
    return 0;
  end

  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];

  if( propMap[PM_Magic] ~= MAGIC ) then
    resultMap.ERROR =  "BROKEN LDT--No Magic";
    info("<<<%s>>>", tostring(resultMap));
    return 0;
  end;

  -- Load the common properties
  propMapSummary( resultMap, propMap );
  info("\n<<<%s>>>\n", tostring(resultMap));
  resultMap = nil;

  -- Reset for each section, otherwise the result would be too much for
  -- the info call to process, and the information would be truncated.
  resultMap = map();
  resultMap.SUMMARY              = "LLIST-SPECIFIC Values";

  -- Load the LLIST-specific properties
  ldtMapSummary( resultMap, ldtMap );
  info("\n<<<%s>>>\n", tostring(resultMap));
  resultMap = nil;

end -- function ldtDebugDump()

-- <><><><> <Initialize Control Maps> <Initialize Control Maps> <><><><>
-- ======================================================================
-- initializeLdtCtrl:
-- ======================================================================
-- Set up the LLIST control structure with the standard (default) values.
-- These values may later be overridden by the user.
-- The structure held in the Record's "LLIST BIN" is this map.  This single
-- structure contains ALL of the settings/parameters that drive the LLIST
-- behavior.  Thus this function represents the "type" LLIST MAP -- all
-- LLIST control fields are defined here.
-- The LListMap is obtained using the user's LLIST Bin Name:
-- ldtCtrl = topRec[ldtBinName]
-- local propMap = ldtCtrl[1];
-- local ldtMap  = ldtCtrl[2];
-- ======================================================================
local function
initializeLdtCtrl( topRec, ldtBinName )
  local meth = "initializeLdtCtrl()";
  GP=E and trace("[ENTER]<%s:%s>:: ldtBinName(%s)",
    MOD, meth, tostring(ldtBinName));

  local propMap = map();
  local ldtMap = map();
  local ldtCtrl = list();

  -- The LLIST control structure -- with Default Values.  Note that we use
  -- two maps -- a general propery map that is the same for all LDTS (in
  -- list position ONE), and then an LDT-specific map.  This design lets us
  -- look at the general property values more easily from the Server code.
  -- General LDT Parms(Same for all LDTs): Held in the Property Map
  propMap[PM_ItemCount] = 0; -- A count of all items in the stack
  propMap[PM_SubRecCount] = 0; -- No Subrecs yet
  propMap[PM_Version]    = G_LDT_VERSION ; -- Current version of the code
  propMap[PM_LdtType]    = LDT_TYPE; -- Validate the ldt type
  propMap[PM_Magic]      = MAGIC; -- Special Validation
  propMap[PM_BinName]    = ldtBinName; -- Defines the LDT Bin
  propMap[PM_RecType]    = RT_LDT; -- Record Type LDT Top Rec
  propMap[PM_EsrDigest]    = 0; -- not set yet.
  propMap[PM_CreateTime] = aerospike:get_current_time();
  propMap[PM_SelfDigest]  = record.digest( topRec );

  -- NOTE: We expect that these settings should match the settings found in
  -- settings_llist.lua :: package.ListMediumObject().
  -- General Tree Settings
  ldtMap[R_TotalCount] = 0;    -- A count of all "slots" used in LLIST
  ldtMap[R_LeafCount] = 0;     -- A count of all Leaf Nodes
  ldtMap[R_NodeCount] = 0;     -- A count of all Nodes (incl leaves, excl root)
  ldtMap[M_StoreMode] = SM_LIST; -- SM_LIST or SM_BINARY (applies to Leaves))
  ldtMap[R_TreeLevel] = 1;     -- Start off Lvl 1: Root ONLY. Leaves Come l8tr
  ldtMap[M_KeyType]   = KT_COMPLEX;-- atomic or complex
  ldtMap[R_KeyUnique] = AS_TRUE; -- Keys ARE unique by default.
  ldtMap[M_Transform] = nil; -- (set later) transform Func (user to storage)
  ldtMap[M_UnTransform] = nil; -- (set later) Un-transform (storage to user)
  ldtMap[R_StoreState] = SS_COMPACT; -- start in "compact mode"
  ldtMap[R_Threshold] = DEFAULT_THRESHOLD;-- Amount to Move out of compact mode

  -- Fixed Key and Object sizes -- when using Binary Storage
  ldtMap[R_KeyByteSize] = 0;   -- Size of a fixed size key
  ldtMap[R_KeyByteSize] = 0;   -- Size of a fixed size key

  -- Top Node Tree Root Directory
  ldtMap[R_RootListMax] = 100; -- Length of Key List (page list is KL + 1)
  ldtMap[R_RootByteCountMax] = 0; -- Max bytes for key space in the root
  ldtMap[R_KeyByteArray] = nil; -- Byte Array, when in compressed mode
  ldtMap[R_DigestByteArray] = nil; -- DigestArray, when in compressed mode
  ldtMap[R_RootKeyList] = list();    -- Key List, when in List Mode
  ldtMap[R_RootDigestList] = list(); -- Digest List, when in List Mode
  ldtMap[R_CompactList] = list();-- Simple Compact List -- before "tree mode"
  
  -- LLIST Inner Node Settings
  ldtMap[R_NodeListMax] = 200;  -- Max # of items (key+digest)
  ldtMap[R_NodeByteCountMax] = 0; -- Max # of BYTES

  -- LLIST Tree Leaves (Data Pages)
  ldtMap[R_LeafListMax] = 200;  -- Max # of items
  ldtMap[R_LeafByteCountMax] = 0; -- Max # of BYTES per data page

  -- If the topRec already has an LDT CONTROL BIN (with a valid map in it),
  -- then we know that the main LDT record type has already been set.
  -- Otherwise, we should set it. This function will check, and if necessary,
  -- set the control bin.
  -- This method also sets this toprec as an LDT type record.
  ldt_common.setLdtRecordType( topRec );
  
  -- Set the BIN Flag type to show that this is an LDT Bin, with all of
  -- the special priviledges and restrictions that go with it.
  GP=F and trace("[DEBUG]:<%s:%s>About to call record.set_flags(Bin(%s)F(%s))",
    MOD, meth, ldtBinName, tostring(BF_LDT_BIN) );

  -- Put our new map in the record, then store the record.
  list.append( ldtCtrl, propMap );
  list.append( ldtCtrl, ldtMap );
  topRec[ldtBinName] = ldtCtrl;
  record.set_flags( topRec, ldtBinName, BF_LDT_BIN );

  GP=F and trace("[DEBUG]: <%s:%s> Back from calling record.set_flags()",
  MOD, meth );

  GP=E and trace("[EXIT]: <%s:%s> : CTRL Map after Init(%s)",
      MOD, meth, ldtSummaryString(ldtCtrl));

  return ldtCtrl;
end -- initializeLdtCtrl()

-- ======================================================================
-- adjustLdtMap:
-- ======================================================================
-- Using the settings supplied by the caller in the LDT Create call,
-- we adjust the values in the LdtMap:
-- Parms:
-- (*) ldtCtrl: the main LDT Bin value (propMap, ldtMap)
-- (*) argListMap: Map of LDT Settings 
-- Return: The updated LdtList
-- ======================================================================
local function adjustLdtMap( ldtCtrl, argListMap )
  local meth = "adjustLdtMap()";
  local propMap = ldtCtrl[1];
  local ldtMap = ldtCtrl[2];

  GP=E and trace("[ENTER]: <%s:%s>:: LdtCtrl(%s)::\n ArgListMap(%s)",
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
      local ldtPackage = llistPackage[value];
      if( ldtPackage ~= nil ) then
        ldtPackage( ldtMap );
      end
    end
  end -- for each argument

  GP=E and trace("[EXIT]:<%s:%s>:LdtCtrl after Init(%s)",
  MOD,meth,tostring(ldtCtrl));
  return ldtCtrl;
end -- adjustLdtMap


-- ======================================================================
-- |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- || B+ Tree Data Page Record |||||||||||||||||||||||||||||||||||||||||||
-- |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- ======================================================================
-- Records used for B+ Tree Leaf Nodes have four bins:
-- Each LDT Data Record (LDR) holds a small amount of control information
-- and a list.  A LDR will have four bins:
-- (1) A Property Map Bin (the same for all LDT subrecords)
-- (2) The Control Bin (a Map with the various control data)
-- (3) The Data List Bin -- where we hold Object "list entries"
-- (4) The Binary Bin -- (Optional) where we hold compacted binary entries
--    (just the as bytes values)
--
-- Records used for B+ Tree Inner Nodes have five bins:
-- (1) A Property Map Bin (the same for all LDT subrecords)
-- (2) The Control Bin (a Map with the various control data)
-- (3) The key List Bin -- where we hold Key "list entries"
-- (4) The Digest List Bin -- where we hold the digests
-- (5) The Binary Bin -- (Optional) where we hold compacted binary entries
--    (just the as bytes values)
-- (*) Although logically the Directory is a list of pairs (Key, Digest),
--     in fact it is two lists: Key List, Digest List, where the paired
--     Key/Digest have the same index entry in the two lists.
-- (*) Note that ONLY ONE of the two content bins will be used.  We will be
--     in either LIST MODE (bin 3) or BINARY MODE (bin 5)
-- ==> 'ldtControlBin' Contents (a Map)
--    + 'TopRecDigest': to track the parent (root node) record.
--    + 'Digest' (the digest that we would use to find this chunk)
--    + 'ItemCount': Number of valid items on the page:
--    + 'TotalCount': Total number of items (valid + deleted) used.
--    + 'Bytes Used': Number of bytes used, but ONLY when in "byte mode"
--    + 'Design Version': Decided by the code:  DV starts at 1.0
--    + 'Log Info':(Log Sequence Number, for when we log updates)
--
--  ==> 'ldtListBin' Contents (A List holding entries)
--  ==> 'ldtBinaryBin' Contents (A single BYTE value, holding packed entries)
--    + Note that the Size and Count fields are needed for BINARY and are
--      kept in the control bin (EntrySize, ItemCount)
--
--    -- Entry List (Holds entry and, implicitly, Entry Count)
  
-- ======================================================================
-- |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- || Initialize Interior B+ Tree Nodes  (Records) |||||||||||||||||||||||
-- |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- ======================================================================
-- ======================================================================
-- |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- || B+ Tree Data Page Record |||||||||||||||||||||||||||||||||||||||||||
-- |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- ======================================================================
-- Records used for B+ Tree modes have three bins:
-- Chunks hold the actual entries. Each LDT Data Record (LDR) holds a small
-- amount of control information and a list.  A LDR will have three bins:
-- (1) The Control Bin (a Map with the various control data)
-- (2) The Data List Bin ('DataListBin') -- where we hold "list entries"
-- (3) The Binary Bin -- where we hold compacted binary entries (just the
--     as bytes values)
-- (*) Although logically the Directory is a list of pairs (Key, Digest),
--     in fact it is two lists: Key List, Digest List, where the paired
--     Key/Digest have the same index entry in the two lists.
-- (*) Note that ONLY ONE of the two content bins will be used.  We will be
--     in either LIST MODE (bin 2) or BINARY MODE (bin 3)
-- ==> 'LdtControlBin' Contents (a Map)
--    + 'TopRecDigest': to track the parent (root node) record.
--    + 'Digest' (the digest that we would use to find this chunk)
--    + 'ItemCount': Number of valid items on the page:
--    + 'TotalCount': Total number of items (valid + deleted) used.
--    + 'Bytes Used': Number of bytes used, but ONLY when in "byte mode"
--    + 'Design Version': Decided by the code:  DV starts at 1.0
--    + 'Log Info':(Log Sequence Number, for when we log updates)
--
--  ==> 'LdtListBin' Contents (A List holding entries)
--  ==> 'LdtBinaryBin' Contents (A single BYTE value, holding packed entries)
--    + Note that the Size and Count fields are needed for BINARY and are
--      kept in the control bin (EntrySize, ItemCount)
--
--    -- Entry List (Holds entry and, implicitly, Entry Count)
-- ======================================================================
-- <><><><><> -- <><><><><> -- <><><><><> -- <><><><><> -- <><><><><> --
--           Large Ordered List (LLIST) Utility Functions
-- <><><><><> -- <><><><><> -- <><><><><> -- <><><><><> -- <><><><><> --
-- ======================================================================
-- These are all local functions to this module and serve various
-- utility and assistance functions.
-- ======================================================================

-- ======================================================================
-- Convenience function to return the Control Map given a subrec
-- ======================================================================
local function getLeafMap( leafSubRec )
  -- local meth = "getLeafMap()";
  -- GP=E and trace("[ENTER]<%s:%s> ", MOD, meth );
  return leafSubRec[LSR_CTRL_BIN]; -- this should be a map.
end -- getLeafMap


-- ======================================================================
-- Convenience function to return the Control Map given a subrec
-- ======================================================================
local function getNodeMap( nodeSubRec )
  -- local meth = "getNodeMap()";
  -- GP=E and trace("[ENTER]<%s:%s> ", MOD, meth );
  return nodeSubRec[NSR_CTRL_BIN]; -- this should be a map.
end -- getNodeMap

-- ======================================================================
-- validateBinName(): Validate that the user's bin name for this large
-- object complies with the rules of Aerospike. Currently, a bin name
-- cannot be larger than 14 characters (a seemingly low limit).
-- ======================================================================
local function validateBinName( ldtBinName )
  local meth = "validateBinName()";

  GP=E and trace("[ENTER]<%s:%s> validate Bin Name(%s)",
    MOD, meth, tostring(ldtBinName));

  if ldtBinName == nil  then
    warn("[ERROR]<%s:%s> Bin Name is NULL", MOD, meth );
    error( ldte.ERR_NULL_BIN_NAME );
  elseif type( ldtBinName ) ~= "string"  then
    warn("[ERROR]<%s:%s> Bin Name is Not a String: Type(%s)", MOD, meth,
      tostring( type(ldtBinName) ));
    error( ldte.ERR_BIN_NAME_NOT_STRING );
  elseif string.len( ldtBinName ) > 14 then
    warn("[ERROR]<%s:%s> Bin Name Too Long::Exceeds 14 characters", MOD, meth);
    error( ldte.ERR_BIN_NAME_TOO_LONG );
  end
  return 0;
end -- validateBinName


-- ======================================================================
-- validateRecBinAndMap():
-- Check that the topRec, the BinName and CrtlMap are valid, otherwise
-- jump out with an error() call. Notice that we look at different things
-- depending on whether or not "mustExist" is true.
-- Parms:
-- (*) topRec: the Server record that holds the Large Map Instance
-- (*) ldtBinName: The name of the bin for the Large Map
-- (*) mustExist: if true, complain if the ldtBin  isn't perfect.
-- Result:
--   If mustExist == true, and things Ok, return ldtCtrl.
-- ======================================================================
local function validateRecBinAndMap( topRec, ldtBinName, mustExist )
  local meth = "validateRecBinAndMap()";
  GP=E and trace("[ENTER]:<%s:%s> BinName(%s) ME(%s)",
    MOD, meth, tostring( ldtBinName ), tostring( mustExist ));

  -- Start off with validating the bin name -- because we might as well
  -- flag that error first if the user has given us a bad name.
  validateBinName( ldtBinName );

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
    if propMap[PM_Magic] ~= MAGIC or propMap[PM_LdtType] ~= LDT_TYPE then
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

    if( G_LDT_VERSION > dataVersion ) then
      warn("[ERROR EXIT]<%s:%s> Code Version (%d) <> Data Version(%d)",
        MOD, meth, G_LDT_VERSION, dataVersion );
      warn("[Please reload data:: Automatic Data Upgrade not yet available");
      error( ldte.ERR_VERSION_MISMATCH );
    end
  end -- final version check

  GP=E and trace("[EXIT]<%s:%s> OK", MOD, meth);
  return ldtCtrl; -- Save the caller the effort of extracting the map.
end -- validateRecBinAndMap()


-- ======================================================================
-- Summarize the List (usually ResultList) so that we don't create
-- huge amounts of crap in the console.
-- Show Size, First Element, Last Element
-- ======================================================================
local function summarizeList( myList )
  local resultMap = map();
  resultMap.Summary = "Summary of the List";
  local listSize  = list.size( myList );
  resultMap.ListSize = listSize;
  if resultMap.ListSize == 0 then
    resultMap.FirstElement = "List Is Empty";
    resultMap.LastElement = "List Is Empty";
  else
    resultMap.FirstElement = tostring( myList[1] );
    resultMap.LastElement =  tostring( myList[listSize] );
  end

  return tostring( resultMap );
end -- summarizeList()

-- ======================================================================
-- printRoot( topRec, ldtCtrl )
-- ======================================================================
-- Dump the Root contents for Debugging/Tracing purposes
-- ======================================================================
local function printRoot( topRec, ldtCtrl )
  -- Extract the property map and control map from the ldt bin list.
  local pMap       = ldtCtrl[1];
  local cMap       = ldtCtrl[2];
  local keyList    = cMap[R_RootKeyList];
  local digestList = cMap[R_RootDigestList];
  local ldtBinName    = pMap[PM_BinName];
  -- if( F == true ) then
    trace("\n RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR");
    trace("\n ROOT::Bin(%s)", ldtBinName );
    trace("\n ROOT::PMAP(%s)", tostring( pMap ) );
    trace("\n ROOT::CMAP(%s)", tostring( cMap ) );
    trace("\n ROOT::KeyList(%s)", tostring( keyList ) );
    trace("\n ROOT::DigestList(%s)", tostring( digestList ) );
  -- end
end -- printRoot()

-- ======================================================================
-- printNode( topRec, ldtCtrl )
-- ======================================================================
-- Dump the Node contents for Debugging/Tracing purposes
-- ======================================================================
local function printNode( nodeSubRec )
  local pMap        = nodeSubRec[SUBREC_PROP_BIN];
  local cMap        = nodeSubRec[NSR_CTRL_BIN];
  local keyList     = nodeSubRec[NSR_KEY_LIST_BIN];
  local digestList  = nodeSubRec[NSR_DIGEST_BIN];
  -- if( F == true ) then
    trace("\n NNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN");
    trace("\n NODE::PMAP(%s)", tostring( pMap ) );
    trace("\n NODE::CMAP(%s)", tostring( cMap ) );
    trace("\n NODE::KeyList(%s)", tostring( keyList ) );
    trace("\n NODE::DigestList(%s)", tostring( digestList ) );
  -- end
end -- printNode()

-- ======================================================================
-- printLeaf( topRec, ldtCtrl )
-- ======================================================================
-- Dump the Leaf contents for Debugging/Tracing purposes
-- ======================================================================
local function printLeaf( leafSubRec )
  local pMap     = leafSubRec[SUBREC_PROP_BIN];
  local cMap     = leafSubRec[LSR_CTRL_BIN];
  local objList  = leafSubRec[LSR_LIST_BIN];
  -- if( F == true ) then
    trace("\n LLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLL");
    trace("\n LEAF::PMAP(%s)", tostring( pMap ) );
    trace("\n LEAF::CMAP(%s)", tostring( cMap ) );
    trace("\n LEAF::ObjectList(%s)", tostring( objList ) );
  -- end
end -- printLeaf()

-- ======================================================================
-- rootNodeSummary( ldtCtrl )
-- ======================================================================
-- Print out interesting stats about this B+ Tree Root
-- ======================================================================
local function rootNodeSummary( ldtCtrl )
  local resultMap = ldtCtrl;

  -- Add to this -- move selected fields into resultMap and return it.

  return tostring( ldtSummary( ldtCtrl )  );
end -- rootNodeSummary()

-- ======================================================================
-- nodeSummary( nodeSubRec )
-- nodeSummaryString( nodeSubRec )
-- ======================================================================
-- Print out interesting stats about this Interior B+ Tree Node
-- ======================================================================
local function nodeSummary( nodeSubRec )
  local meth = "nodeSummary()";
  local resultMap = map();
  local propMap  = nodeSubRec[SUBREC_PROP_BIN];
  local nodeCtrlMap  = nodeSubRec[NSR_CTRL_BIN];
  local keyList = nodeSubRec[NSR_KEY_LIST_BIN];
  local digestList = nodeSubRec[NSR_DIGEST_BIN];

  -- General Properties (the Properties Bin)
  resultMap.SUMMARY           = "NODE Summary";
  resultMap.PropMagic         = propMap[PM_Magic];
  resultMap.PropCreateTime    = propMap[PM_CreateTime];
  resultMap.PropEsrDigest     = propMap[PM_EsrDigest];
  resultMap.PropRecordType    = propMap[PM_RecType];
  resultMap.PropParentDigest  = propMap[PM_ParentDigest];
  
  -- Node Control Map
  resultMap.ListEntryCount = nodeCtrlMap[ND_ListEntryCount];
  resultMap.ListEntryTotal = nodeCtrlMap[ND_ListEntryTotal];

  -- Node Contents (Object List)
  resultMap.KEY_LIST              = keyList;
  resultMap.DIGEST_LIST           = digestList;

  return resultMap;
end -- nodeSummary()

local function nodeSummaryString( nodeSubRec )
  return tostring( nodeSummary( nodeSubRec ) );
end -- nodeSummaryString()

-- ======================================================================
-- leafSummary( leafSubRec )
-- leafSummaryString( leafSubRec )
-- ======================================================================
-- Print out interesting stats about this B+ Tree Leaf (Data) node
-- ======================================================================
local function leafSummary( leafSubRec )
  if( leafSubRec == nil ) then
    return "NIL Leaf Record";
  end

  local resultMap = map();
  local propMap   = leafSubRec[SUBREC_PROP_BIN];
  local leafMap   = leafSubRec[LSR_CTRL_BIN];
  local leafList  = leafSubRec[LSR_LIST_BIN];

  -- General Properties (the Properties Bin)
  resultMap.SUMMARY           = "LEAF Summary";
  resultMap.PropMagic         = propMap[PM_Magic];
  resultMap.PropCreateTime    = propMap[PM_CreateTime];
  resultMap.PropEsrDigest     = propMap[PM_EsrDigest];
  resultMap.PropSelfDigest    = propMap[PM_SelfDigest];
  resultMap.PropRecordType    = propMap[PM_RecType];
  resultMap.PropParentDigest  = propMap[PM_ParentDigest];

  trace("[LEAF PROPS]: %s", tostring(resultMap));
  
  -- Leaf Control Map
  resultMap.LF_ListEntryCount = leafMap[LF_ListEntryCount];
  resultMap.LF_ListEntryTotal = leafMap[LF_ListEntryTotal];
  resultMap.LF_PrevPage       = leafMap[LF_PrevPage];
  resultMap.LF_NextPage       = leafMap[LF_NextPage];

  -- Leaf Contents (Object List)
  resultMap.LIST              = leafList;

  return resultMap;
end -- leafSummary()

local function leafSummaryString( leafSubRec )
  return tostring( leafSummary( leafSubRec ) );
end

-- ======================================================================
-- ======================================================================
local function showRecSummary( nodeSubRec, propMap )
  local meth = "showRecSummary()";
  -- Debug/Tracing to see what we're putting in the SubRec Context
  -- if( F == true ) then
  if( propMap == nil ) then
    warn("[ERROR]<%s:%s>: propMap value is NIL", MOD, meth );
    error( ldte.ERR_SUBREC_DAMAGED );
  end
    GP=F and trace("\n[SUBREC DEBUG]:: SRC Contents \n");
    local recType = propMap[PM_RecType];
    if( recType == RT_LEAF ) then
      GP=F and trace("\n[Leaf Record Summary] %s\n",leafSummaryString(nodeSubRec));
    elseif( recType == RT_NODE ) then
      GP=F and trace("\n[Node Record Summary] %s\n",nodeSummaryString(nodeSubRec));
    else
      GP=F and trace("\n[OTHER Record TYPE] (%s)\n", tostring( recType ));
    end
  -- end
end -- showRecSummary()

-- ======================================================================
-- SUB RECORD CONTEXT DESIGN NOTE:
-- All "outer" functions, like insert(), search(), remove(),
-- will employ the "subrecContext" object, which will hold all of the
-- subrecords that were opened during processing.  Note that with
-- B+ Trees, operations like insert() can potentially involve many subrec
-- operations -- and can also potentially revisit pages.  In addition,
-- we employ a "compact list", which gets converted into tree inserts when
-- we cross a threshold value, so that will involve MANY subrec "re-opens"
-- that would confuse the underlying infrastructure.
--
-- SubRecContext Design:
-- The key will be the DigestString, and the value will be the subRec
-- pointer.  At the end of an outer call, we will iterate thru the subrec
-- context and close all open subrecords.  Note that we may also need
-- to mark them dirty -- but for now we'll update them in place (as needed),
-- but we won't close them until the end.
-- ======================================================================
-- NOTE: We are now using ldt_common.createSubRecContext()
-- ======================================================================

-- ======================================================================
-- Produce a COMPARABLE value (our overloaded term here is "key") from
-- the user's value.
-- The value is either simple (atomic), in which case we just return the
-- value, or an object (complex), in which case we must perform some operation
-- to extract an atomic value that can be compared.  For LLIST, we do one
-- additional thing, which is to look for a field in the complex object
-- called "key" (lower case "key") if no other KeyFunction is supplied.
--
-- Parms:
-- (*) ldtMap: The basic LDT Control structure
-- (*) value: The value from which we extract a "keyValue" that can be
--            compared in an ordered compare operation.
-- Return a comparable keyValue:
-- ==> The original value, if it is an atomic type
-- ==> A Unique Identifier subset (that is atomic)
-- ==> The entire object, in string form.
-- ======================================================================
local function getKeyValue( ldtMap, value )
  local meth = "getKeyValue()";
  GD=DEBUG and trace("[ENTER]<%s:%s> value(%s) KeyType(%s)",
    MOD, meth, tostring(value), tostring(ldtMap[M_KeyType]) );

  if( value == nil ) then
    GP=E and trace("[Early EXIT]<%s:%s> Value is nil", MOD, meth );
    return nil;
  end

  GD=DEBUG and trace("[DEBUG]<%s:%s> Value type(%s)", MOD, meth,
    tostring( type(value)));

  local keyValue;
  if( ldtMap[M_KeyType] == KT_ATOMIC or type(value) ~= "userdata" ) then
    keyValue = value;
  else
    if( G_KeyFunction ~= nil ) then
      -- Employ the user's supplied function (keyFunction) and if that's not
      -- there, look for the special case where the object has a field
      -- called "key".  If not, then, well ... tough.  We tried.
      keyValue = G_KeyFunction( value );
    elseif( value[KEY_FIELD] ~= nil ) then
      -- Use the default action of using the object's KEY field
      keyValue = value[KEY_FIELD];
    else
      -- It's an ERROR in Large List to have a Complex Object and NOT
      -- define either a KeyFunction or a Key Field.  Complain.
      warn("[ERROR]<%s:%s> LLIST requires a KeyFunction for Objects",
        MOD, meth );
      error( ldte.ERR_KEY_FUN_NOT_FOUND );
    end
  end

  GD=DEBUG and trace("[EXIT]<%s:%s> Result(%s)", MOD, meth,tostring(keyValue));
  return keyValue;
end -- getKeyValue();

-- ======================================================================
-- keyCompare: (Compare ONLY Key values, not Object values)
-- ======================================================================
-- Compare Search Key Value with KeyList, following the protocol for data
-- compare types.  Since compare uses only atomic key types (the value
-- that would be the RESULT of the extractKey() function), we can do the
-- simple compare here, and we don't need "keyType".
-- CR_LESS_THAN    (-1) for searchKey <  dataKey,
-- CR_EQUAL        ( 0) for searchKey == dataKey,
-- CR_GREATER_THAN ( 1) for searchKey >  dataKey
-- Return CR_ERROR (-2) if either of the values is null (or other error)
-- Return CR_INTERNAL_ERROR(-3) if there is some (weird) internal error
-- ======================================================================
local function keyCompare( searchKey, dataKey )
  local meth = "keyCompare()";
  GD=DEBUG and trace("[ENTER]<%s:%s> searchKey(%s) data(%s)",
    MOD, meth, tostring(searchKey), tostring(dataKey));

  local result = CR_INTERNAL_ERROR; -- we should never be here.
  -- First check
  if ( dataKey == nil ) then
    warn("[WARNING]<%s:%s> DataKey is nil", MOD, meth );
    result = CR_ERROR;
  elseif( searchKey == nil ) then
    -- a nil search key is always LESS THAN everything.
    result = CR_LESS_THAN;
  else
    if searchKey == dataKey then
      result = CR_EQUAL;
    elseif searchKey < dataKey then
      result = CR_LESS_THAN;
    else
      result = CR_GREATER_THAN;
    end
  end

  GD=DEBUG and trace("[EXIT]:<%s:%s> Result(%d)", MOD, meth, result );
  return result;
end -- keyCompare()

-- ======================================================================
-- objectCompare: Compare a key with a complex object
-- ======================================================================
-- Compare Search Value with data, following the protocol for data
-- compare types.
-- Parms:
-- (*) ldtMap: control map for LDT
-- (*) searchKey: Key value we're comparing (if nil, always true)
-- (*) objectValue: Atomic or Complex Object (the LIVE object)
-- Return:
-- CR_LESS_THAN    (-1) for searchKey <   objectKey
-- CR_EQUAL        ( 0) for searchKey ==  objectKey,
-- CR_GREATER_THAN ( 1) for searchKey >   objectKey
-- Return CR_ERROR (-2) if Key or Object is null (or other error)
-- Return CR_INTERNAL_ERROR(-3) if there is some (weird) internal error
-- ======================================================================
local function objectCompare( ldtMap, searchKey, objectValue )
  local meth = "objectCompare()";
  local keyType = ldtMap[M_KeyType];

  GD=DEBUG and trace("[ENTER]<%s:%s> keyType(%s) searchKey(%s) data(%s)",
    MOD, meth, tostring(keyType), tostring(searchKey), tostring(objectValue));

  local result = CR_INTERNAL_ERROR; -- Expect result to be reassigned.

  -- First check
  if ( objectValue == nil ) then
    warn("[WARNING]<%s:%s> ObjectValue is nil", MOD, meth );
    result = CR_ERROR;
  elseif( searchKey == nil ) then
    GP=F and trace("[INFO]<%s:%s> searchKey is nil:Free Pass", MOD, meth );
    result = CR_EQUAL;
  else
    -- Get the key value for the object -- this could either be the object 
    -- itself (if atomic), or the result of a function that computes the
    -- key from the object.
    local objectKey = getKeyValue( ldtMap, objectValue );
    if( type(objectKey) ~= type(searchKey) ) then
      warn("[INFO]<%s:%s> ObjectValue::SearchKey TYPE Mismatch", MOD, meth );
      warn("[INFO] TYPE ObjectValue(%s) TYPE SearchKey(%s)",
        type(objectKey), type(searchKey) );
      -- Generate the error here for mismatched types.
      error(ldte.ERR_TYPE_MISMATCH);
    end

    -- For atomic types (keyType == 0), compare objects directly
    if searchKey == objectKey then
      result = CR_EQUAL;
    elseif searchKey < objectKey then
      result = CR_LESS_THAN;
    else
      result = CR_GREATER_THAN;
    end
  end -- else compare

  GD=DEBUG and trace("[EXIT]:<%s:%s> Result(%d)", MOD, meth, result );
  return result;
end -- objectCompare()

-- =======================================================================
--     Node (key) Searching:
-- =======================================================================
--        Index:   1   2   3   4
--     Key List: [10, 20, 30]
--     Dig List: [ A,  B,  C,  D]
--     +--+--+--+                        +--+--+--+
--     |10|20|30|                        |40|50|60| 
--     +--+--+--+                        +--+--+--+
--    / 1 |2 |3  \4 (index)             /   |  |   \
--   A    B  C    D (Digest Ptr)       E    F  G    H
--
--   Child A: all values < 10
--   Child B: all values >= 10 and < 20
--   Child C: all values >= 20 and < 30
--   Child D: all values >= 30
--   (1) Looking for value 15:  (SV=15, Obj=x)
--       : 15 > 10, keep looking
--       : 15 < 20, want Child B (same index ptr as value (2)
--   (2) Looking for value 30:  (SV=30, Obj=x)
--       : 30 > 10, keep looking
--       : 30 > 20, keep looking
--       : 30 = 30, want Child D (same index ptr as value (2)
--   (3) Looking for value 31:  (SV=31, Obj=x)
--       : 31 > 10, keep looking
--       : 31 > 20, keep looking
--       : 31 > 30, At End = want child D
--   (4) Looking for value 5:  (SV=5, Obj=x)
--       : 5 < 10, Want Child A


-- ======================================================================
-- initPropMap( propMap, esrDigest, selfDigest, topDigest, rtFlag, topPropMap )
-- ======================================================================
-- -- Set up the LDR Property Map (one PM per LDT)
-- Parms:
-- (*) propMap: 
-- (*) esrDigest:
-- (*) selfDigest:
-- (*) topDigest:
-- (*) rtFlag:
-- (*) topPropMap:
-- ======================================================================
local function
initPropMap( propMap, esrDigest, selfDigest, topDigest, rtFlag, topPropMap )
  local meth = "initPropMap()";
  GP=E and trace("[ENTER]<%s:%s>", MOD, meth );

  -- Remember the ESR in the Top Record
  topPropMap[PM_EsrDigest] = esrDigest;

  -- Initialize the PropertyMap of the new ESR
  propMap[PM_EsrDigest]    = esrDigest;
  propMap[PM_RecType  ]    = rtFlag;
  propMap[PM_Magic]        = MAGIC;
  propMap[PM_ParentDigest] = topDigest;
  propMap[PM_SelfDigest]   = selfDigest;
  -- For subrecs, set create time to ZERO.
  propMap[PM_CreateTime]   = 0;

  GP=E and trace("[EXIT]: <%s:%s>", MOD, meth );
end -- initPropMap()

-- ======================================================================
-- searchKeyList(): Search the Key list in a Root or Inner Node
-- ======================================================================
-- Search the key list, return the index of the value that represents the
-- child pointer that we should follow.  Notice that this is DIFFERENT
-- from the Leaf Search, which treats the EQUAL case differently.
-- ALSO -- the Objects in the Leaves may be TRANSFORMED (e.g. compressed),
-- so they potentially need to be UN-TRANSFORMED before they can be
-- read.
--
-- For this example:
--              +---+---+---+---+
-- KeyList      |111|222|333|444|
--              +---+---+---+---+
-- DigestList   A   B   C   D   E
--
-- Search Key 100:  Position 1 :: Follow Child Ptr A
-- Search Key 111:  Position 2 :: Follow Child Ptr B
-- Search Key 200:  Position 2 :: Follow Child Ptr B
-- Search Key 222:  Position 2 :: Follow Child Ptr C
-- Search Key 555:  Position 5 :: Follow Child Ptr E
-- Parms:
-- (*) ldtMap: Main control Map
-- (*) keyList: The list of keys (from root or inner node)
-- (*) searchKey: if nil, then is always LESS THAN the list
-- Return:
-- OK: Return the Position of the Digest Pointer that we want
-- ERRORS: Return ERR_GENERAL (bad compare)
-- ======================================================================
local function searchKeyList( ldtMap, keyList, searchKey )
  local meth = "searchKeyList()";
  GP=E and trace("[ENTER]<%s:%s>searchKey(%s)", MOD,meth,tostring(searchKey));

  -- We can short-cut this.  If searchKey is nil, then we automatically
  -- return 1 (the first index position).
  if( searchKey == nil ) then
    return 1;
  end

  -- Don't need this at the moment.
  -- local keyType = ldtMap[M_KeyType];

  -- Linear scan of the KeyList.  Find the appropriate entry and return
  -- the index.  Binary Search will come later.
  local resultIndex = 0;
  local compareResult = 0;
  -- Do the List page mode search here
  local listSize = list.size( keyList );
  local entryKey;
  for i = 1, listSize, 1 do
    GP=F and trace("[DEBUG]<%s:%s>searchKey(%s) i(%d) keyList(%s)",
    MOD, meth, tostring(searchKey), i, tostring(keyList));

    entryKey = keyList[i];
    compareResult = keyCompare( searchKey, entryKey );
    if compareResult == CR_ERROR then
      return ERR_GENERAL; -- error result.
    end
    if compareResult  == CR_LESS_THAN then
      -- We want the child pointer that goes with THIS index (left ptr)
      GP=F and trace("[Stop Search: Key < Data]: <%s:%s> : SK(%s) EK(%s) I(%d)",
        MOD, meth, tostring(searchKey), tostring( entryKey ), i );
        return i; -- Left Child Pointer
    elseif compareResult == CR_EQUAL then
      -- Found it -- return the "right child" index (right ptr)
      GP=F and trace("[FOUND KEY]: <%s:%s> : SrchValue(%s) Index(%d)",
        MOD, meth, tostring(searchKey), i);
      return i + 1; -- Right Child Pointer
    end
    -- otherwise, keep looking.  We haven't passed the spot yet.
  end -- for each list item

  -- Remember: Can't use "i" outside of Loop.   
  GP=F and trace("[FOUND GREATER THAN]: <%s:%s> SKey(%s) EKey(%s) Index(%d)",
    MOD, meth, tostring(searchKey), tostring(entryKey), listSize + 1 );

  return listSize + 1; -- return furthest right child pointer
end -- searchKeyList()

-- ======================================================================
-- searchObjectList(): Search the Object List in a Leaf Node
-- ======================================================================
-- Search the Object list, return the index of the value that is THE FIRST
-- object to match the search Key. Notice that this method is different
-- from the searchKeyList() -- since that is only looking for the right
-- leaf.  In searchObjectList() we're looking for the actual value.
-- NOTE: Later versions of this method will probably return a location
-- of where to start scanning (for value ranges and so on).  But, for now,
-- we're just looking for an exact match.
-- For this example:
--              +---+---+---+---+
-- ObjectList   |111|222|333|444|
--              +---+---+---+---+
-- Index:         1   2   3   4
--
-- Search Key 100:  Position 1 :: Insert at index location 1
-- Search Key 111:  Position 1 :: Insert at index location 1
-- Search Key 200:  Position 2 :: Insert at index location 2
-- Search Key 222:  Position 2 :: Insert at index location 2
-- Parms:
-- (*) ldtMap: Main control Map
--
-- Parms:
-- (*) ldtMap: Main control Map
-- (*) objectList: The list of keys (from root or inner node)
-- (*) searchKey: if nil, then it compares LESS than everything.
-- Return: Returns a STRUCTURE (a map)
-- (*) POSITION: (where we found it if true, or where we would insert if false)
-- (*) FOUND RESULTS (true, false)
-- (*) ERROR Status: Ok, or Error
--
-- OK: Return the Position of the first matching value.
-- ERRORS:
-- ERR_GENERAL   (-1): Trouble
-- ERR_NOT_FOUND (-2): Item not found.
-- ======================================================================
local function searchObjectList( ldtMap, objectList, searchKey )
  local meth = "searchObjectList()";
  local keyType = ldtMap[M_KeyType];
  GD=DEBUG and trace("[ENTER]<%s:%s>searchKey(%s) keyType(%s) ObjList(%s)",
    MOD, meth, tostring(searchKey), tostring(keyType), tostring(objectList));

  local resultMap = map();
  resultMap.Status = ERR_OK;

  -- If we're given a nil searchKey, then we say "found" and return
  -- position 1 -- basically, to set up Scan.
  if( searchKey == nil ) then
    resultMap.Found = true;
    resultMap.Position = 1;
    GP=E and trace("[EARLY EXIT]<%s:%s> SCAN: Nil Key", MOD, meth );
    return resultMap;
  end

  resultMap.Found = false;
  resultMap.Position = 0;

  -- Linear scan of the ObjectList.  Find the appropriate entry and return
  -- the index.  Binary Search will come later.  Binary search is messy with
  -- duplicates.
  local resultIndex = 0;
  local compareResult = 0;
  local objectKey;
  local storeObject; -- the stored (transformed) representation of the object
  local liveObject; -- the live (untransformed) representation of the object

  -- Do the List page mode search here
  local listSize = list.size( objectList );

  GP=F and trace("[Starting LOOP]<%s:%s>", MOD, meth );

  for i = 1, listSize, 1 do
    -- If we have a transform/untransform, do that here.
    storedObject = objectList[i];
    if( G_UnTransform ~= nil ) then
      liveObject = G_UnTransform( storedObject );
    else
      liveObject = storedObject;
    end

    compareResult = objectCompare( ldtMap, searchKey, liveObject );
    if compareResult == CR_ERROR then
      resultMap.status = ERR_GENERAL;
      return resultMap;
    end
    if compareResult  == CR_LESS_THAN then
      -- We want the child pointer that goes with THIS index (left ptr)
      GD=DEBUG and trace("[NOT FOUND LESS THAN]<%s:%s> : SV(%s) Obj(%s) I(%d)",
        MOD, meth, tostring(searchKey), tostring(liveObject), i );
      resultMap.Position = i;
      return resultMap;
    elseif compareResult == CR_EQUAL then
      -- Found it -- return the index of THIS value
      GD=DEBUG and trace("[FOUND KEY]: <%s:%s> :Key(%s) Value(%s) Index(%d)",
        MOD, meth, tostring(searchKey), tostring(liveObject), i );
      resultMap.Position = i; -- Index of THIS value.
      resultMap.Found = true;
      return resultMap;
    end
    -- otherwise, keep looking.  We haven't passed the spot yet.
  end -- for each list item

  -- Remember: Can't use "i" outside of Loop.   
  GP=F and trace("[NOT FOUND: EOL]: <%s:%s> :Key(%s) Final Index(%d)",
    MOD, meth, tostring(searchKey), listSize );

  resultMap.Position = listSize + 1;
  resultMap.Found = false;

  GP=E and trace("[EXIT]<%s:%s>ResultMap(%s)", MOD,meth,tostring(resultMap));
  return resultMap;
end -- searchObjectList()

-- ======================================================================
-- For debugging purposes, print the tree, starting with the root and
-- then each level down.
-- Root
-- ::Root Children
-- ::::Root Grandchildren
-- :::...::: Leaves
-- ======================================================================
local function printTree( src, topRec, ldtBinName )
  local meth = "printTree()";
  GP=E and trace("[ENTER]<%s:%s> BinName(%s) SRC(%s)",
    MOD, meth, ldtBinName, tostring(src));
  -- Start with the top level structure and descend from there.
  -- At each level, create a new child list, which will become the parent
  -- list for the next level down (unless we're at the leaves).
  -- The root is a special case of a list of parents with a single node.
  local ldtCtrl = topRec[ldtBinName];
  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];
  local nodeList = list();
  local childList = list();
  local digestString;
  local nodeSubRec;
  local treeLevel = ldtMap[R_TreeLevel];

  trace("\n ===========================================================\n");
  trace("\n <PT>begin <PT> <PT> :::::::::::::::::::::::: <PT> <PT> <PT>\n");
  trace("\n <PT> <PT> <PT> :::::   P R I N T   T R E E  ::::: <PT> <PT>\n");
  trace("\n <PT> <PT> <PT> <PT> :::::::::::::::::::::::: <PT> <PT> <PT>\n");
  trace("\n ===========================================================\n");

  trace("\n ======  ROOT SUMMARY ======\n(%s)", rootNodeSummary( ldtCtrl ));

  printRoot( topRec, ldtCtrl );

  nodeList = ldtMap[R_RootDigestList];

  -- The Root is already printed -- now print the rest.
  for lvl = 2, treeLevel, 1 do
    local listSize = list.size( nodeList );
    for n = 1, listSize, 1 do
      digestString = tostring( nodeList[n] );
      GP=F and trace("[SUBREC]<%s:%s> OpenSR(%s)", MOD, meth, digestString );
      nodeSubRec = ldt_common.openSubRec( src, topRec, digestString );
      if( lvl < treeLevel ) then
        -- This is an inner node -- remember all children
        local digestList  = nodeSubRec[NSR_DIGEST_BIN];
        local digestListSize = list.size( digestList );
        for d = 1, digestListSize, 1 do
          list.append( childList, digestList[d] );
        end -- end for each digest in the node
        printNode( nodeSubRec );
      else
        -- This is a leaf node -- just print contents of each leaf
        printLeaf( nodeSubRec );
      end
      GP=F and trace("[SUBREC]<%s:%s> CloseSR(%s)", MOD, meth, digestString );
      -- Mark the SubRec as "done" (available).
      ldt_common.closeSubRec( src, nodeSubRec, false); -- Mark it as available
    end -- for each node in the list
    -- If we're going around again, then the old childList is the new
    -- ParentList (as in, the nodeList for the next iteration)
    nodeList = childList;
  end -- for each tree level

  trace("\n ===========================================================\n");
  trace("\n <PT> <PT> <PT> <PT> <PT>   E N D   <PT> <PT> <PT> <PT> <PT>\n");
  trace("\n ===========================================================\n");
 
  -- Release ALL of the read-only subrecs that might have been opened.
  rc = ldt_common.closeAllSubRecs( src );
  if( rc < 0 ) then
    warn("[EARLY EXIT]<%s:%s> Problem closing subrec in search", MOD, meth );
    error( ldte.ERR_SUBREC_CLOSE );
  end

  GP=E and trace("[EXIT]<%s:%s> ", MOD, meth );
end -- printTree()

-- ======================================================================
-- Update the Leaf Page pointers for a leaf -- used on initial create
-- and leaf splits.  Each leaf has a left and right pointer (digest).
-- Parms:
-- (*) leafSubRec:
-- (*) leftDigest:  Set PrevPage ptr, if not nil
-- (*) rightDigest: Set NextPage ptr, if not nil
-- ======================================================================
local function setLeafPagePointers( src, leafSubRec, leftDigest, rightDigest )
  local meth = "setLeafPagePointers()";
  GP=E and trace("[ENTER]<%s:%s> left(%s) right(%s)",
    MOD, meth, tostring(leftDigest), tostring(rightDigest) );
  leafMap = leafSubRec[LSR_CTRL_BIN];
  if( leftDigest ~= nil ) then
    leafMap[LF_PrevPage] = leftDigest;
  end
  if( leftDigest ~= nil ) then
    leafMap[LF_NextPage] = rightDigest;
  end
  leafSubRec[LSR_CTRL_BIN] = leafMap;
  -- Call udpate to mark the SubRec as dirty, and to force the write if we
  -- are in "early update" mode. Close will happen at the end of the Lua call.
  ldt_common.updateSubRec( src, leafSubRec );

  GP=E and trace("[EXIT]<%s:%s> ", MOD, meth );
end -- setLeafPagePointers()

-- ======================================================================
-- We've just done a Leaf split, so now we have to update the page pointers
-- so that the doubly linked leaf page chain remains intact.
-- When we create pages -- we ALWAYS create a new left page (the right one
-- is the previously existing page).  So, the Next Page ptr of the right
-- page is correct (and its right neighbors are correct).  The only thing
-- to change are the LEFT record ptrs -- the new left and the old left.
--      +---+==>+---+==>+---+==>+---+==>
--      | Xi|   |OL |   | R |   | Xj| Leaves Xi, OL, R and Xj
--   <==+---+<==+---+<==+---+<==+---+
--              +---+
--              |NL | Add in this New Left Leaf to be "R"s new left neighbor
--              +---+
--      +---+==>+---+==>+---+==>+---+==>+---+==>
--      | Xi|   |OL |   |NL |   | R |   | Xj| Leaves Xi, OL, NL, R, Xj
--   <==+---+<==+---+<==+---+<==+---+<==+---+
-- Notice that if "OL" exists, then we'll have to open it just for the
-- purpose of updating the page pointer.  This is a pain, BUT, the alternative
-- is even more annoying, which means a tree traversal for scanning.  So
-- we pay our dues here -- and suffer the extra I/O to open the left leaf,
-- so that our leaf page scanning (in both directions) is easy and sane.
-- We are guaranteed that we'll always have a left leaf and a right leaf,
-- so we don't need to check for that.  However, it is possible that if the
-- old Leaf was the left most leaf (what is "R" in this example), then there
-- would be no "OL".  The left leaf digest value for "R" would be ZERO.
--                       +---+==>+---+=+
--                       | R |   | Xj| V
--                     +=+---+<==+---+
--               +---+ V             +---+==>+---+==>+---+=+
-- Add leaf "NL" |NL |     Becomes   |NL |   | R |   | Xj| V
--               +---+             +=+---+<==+---+<==+---+
--                                 V
--
-- New for Spring 2014 are the LeftLeaf and RightLeaf pointers that we 
-- maintain from the root/control information.  That gets updated when we
-- split the left-most leaf and get a new Left-Most Leaf.  Since we never
-- get a new Right-Most Leaf (at least in regular Split operations), we
-- assign that ONLY with the initial create.
-- ======================================================================
local function adjustPagePointers( src, topRec, ldtMap, newLeftLeaf, rightLeaf )
  local meth = "adjustPagePointers()";
  GP=E and trace("[ENTER]<%s:%s> ", MOD, meth );

  -- We'll denote our leaf recs as "oldLeftLeaf, newLeftLeaf and rightLeaf"
  -- The existing rightLeaf points to the oldLeftLeaf.
  local newLeftLeafDigest = record.digest( newLeftLeaf );
  local rightLeafDigest   = record.digest( rightLeaf );

  GP=F and trace("[DEBUG]<%s:%s> newLeft(%s) oldRight(%s)",
    MOD, meth, tostring(newLeftLeafDigest), tostring(rightLeafDigest) );

  local newLeftLeafMap = newLeftLeaf[LSR_CTRL_BIN];
  local rightLeafMap = rightLeaf[LSR_CTRL_BIN];

  local oldLeftLeafDigest = rightLeafMap[LF_PrevPage];
  if( oldLeftLeafDigest == 0 ) then
    -- There is no left Leaf.  Just assign ZERO to the newLeftLeaf Left Ptr.
    -- Also -- register this leaf as the NEW LEFT-MOST LEAF.
    GP=F and trace("[DEBUG]<%s:%s> No Old Left Leaf (assign ZERO)",MOD, meth );
    newLeftLeafMap[LF_PrevPage] = 0;
    ldtMap[R_LeftLeafDigest] = newLeftLeafDigest;
  else 
    -- Regular situation:  Go open the old left leaf and update it.
    local oldLeftLeafDigestString = tostring(oldLeftLeafDigest);
    local oldLeftLeaf =
        ldt_common.openSubRec( src, topRec, oldLeftLeafDigestString );
    if( oldLeftLeaf == nil ) then
      warn("[ERROR]<%s:%s> oldLeftLeaf NIL from openSubrec: digest(%s)",
        MOD, meth, oldLeftLeafDigestString );
      error( ldte.ERR_SUBREC_OPEN );
    end
    local oldLeftLeafMap = oldLeftLeaf[LSR_CTRL_BIN];
    oldLeftLeafMap[LF_NextPage] = newLeftLeafDigest;
    oldLeftLeaf[LSR_CTRL_BIN] = oldLeftLeafMap;
    -- Call udpate to mark the SubRec as dirty, and to force the write if we
    -- are in "early update" mode. Close will happen at the end of the Lua call.
    ldt_common.updateSubRec( src, oldLeftLeaf );
  end

  -- Now update the new Left Leaf, the Right Leaf, and their page ptrs.
  newLeftLeafMap[LF_PrevPage] = oldLeftLeafDigest;
  newLeftLeafMap[LF_NextPage] = rightLeafDigest;
  rightLeafMap[LF_PrevPage]   = newLeftLeafDigest;
  
  -- Save the Leaf Record Maps, and update the subrecs.
  newLeftLeaf[LSR_CTRL_BIN]   =  newLeftLeafMap;
  rightLeaf[LSR_CTRL_BIN]     = rightLeafMap;
  -- Call udpate to mark the SubRec as dirty, and to force the write if we
  -- are in "early update" mode. Close will happen at the end of the Lua call.
  ldt_common.updateSubRec( src, newLeftLeaf );
  ldt_common.updateSubRec( src, rightLeaf );

  GP=E and trace("[EXIT]<%s:%s> ", MOD, meth );
end -- adjustPagePointers()

-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
--    for i = 1, list.size( objectList ), 1 do
--      compareResult = compare( keyType, searchKey, objectList[i] );
--      if compareResult == -2 then
--        return nil -- error result.
--      end
--      if compareResult == 0 then
--        -- Start gathering up values
--        gatherLeafListData( topRec, leafSubRec, ldtMap, resultList, searchKey,
--          func, fargs, flag );
--        GP=F and trace("[FOUND VALUES]: <%s:%s> : Value(%s) Result(%s)",
--          MOD, meth, tostring(newStorageValue), tostring( resultList));
--          return resultList;
--      elseif compareResult  == 1 then
--        GP=F and trace("[NotFound]: <%s:%s> : Value(%s)",
--          MOD, meth, tostring(newStorageValue) );
--          return resultList;
--      end
--      -- otherwise, keep looking.  We haven't passed the spot yet.
--    end -- for each list item
-- ======================================================================
-- createSearchPath: Create and initialize a search path structure so
-- that we can fill it in during our tree search.
-- Parms:
-- (*) ldtMap: topRec map that holds all of the control values
-- ======================================================================
local function createSearchPath( ldtMap )
  local sp = map();
  sp.LevelCount = 0;
  sp.RecList = list();     -- Track all open nodes in the path
  sp.DigestList = list();  -- The mechanism to open each level
  sp.PositionList = list(); -- Remember where the key was
  sp.HasRoom = list(); -- Check each level so we'll know if we have to split

  -- Cache these here for convenience -- they may or may not be useful
  sp.RootListMax = ldtMap[R_RootListMax];
  sp.NodeListMax = ldtMap[R_NodeListMax];
  sp.LeafListMax = ldtMap[R_LeafListMax];

  return sp;
end -- createSearchPath()

-- ======================================================================
-- updateSearchPath:
-- Add one more entry to the search path thru the B+ Tree.
-- We Rememeber the path that we took during the search
-- so that we can retrace our steps if we need to update the rest of the
-- tree after an insert or delete (although, it's unlikely that we'll do
-- any significant tree change after a delete).
-- Parms:
-- (*) SearchPath: a map that holds all of the secrets
-- (*) propMap: The Property Map (tells what TYPE this record is)
-- (*) ldtMap: Main LDT Control structure
-- (*) nodeSubRec: a subrec
-- (*) position: location in the current list
-- (*) keyCount: Number of keys in the list
-- ======================================================================
local function
updateSearchPath(sp, propMap, ldtMap, nodeSubRec, position, keyCount)
  local meth = "updateSearchPath()";
  local rc = 0;
  GP=E and trace("[ENTER]<%s:%s> SP(%s) PMap(%s) LMap(%s) Pos(%d) KeyCnt(%d)",
    MOD, meth, tostring(sp), tostring(propMap), tostring(ldtMap),
    position, keyCount);

  local levelCount = sp.LevelCount;
  local nodeRecordDigest = record.digest( nodeSubRec );
  sp.LevelCount = levelCount + 1;

  list.append( sp.RecList, nodeSubRec );
  list.append( sp.DigestList, nodeRecordDigest );
  list.append( sp.PositionList, position );
  -- Depending on the Tree Node (Root, Inner, Leaf), we might have different
  -- maximum values.  So, figure out the max, and then figure out if we've
  -- reached it for this node.
  local recType = propMap[PM_RecType];
  local nodeMax = 0;
  if( recType == RT_LDT ) then
      nodeMax = ldtMap[R_RootListMax];
      GP=F and trace("[Root NODE MAX]<%s:%s> Got Max for Root Node(%s)",
        MOD, meth, tostring( nodeMax ));
  elseif( recType == RT_NODE ) then
      nodeMax = ldtMap[R_NodeListMax];
      GP=F and trace("[Inner NODE MAX]<%s:%s> Got Max for Inner Node(%s)",
        MOD, meth, tostring( nodeMax ));
  elseif( recType == RT_LEAF ) then
      nodeMax = ldtMap[R_LeafListMax];
      GP=F and trace("[Leaf NODE MAX]<%s:%s> Got Max for Leaf Node(%s)",
        MOD, meth, tostring( nodeMax ));
  else
      warn("[ERROR]<%s:%s> Bad Node Type (%s) in UpdateSearchPath", 
        MOD, meth, tostring( recType ));
      error( ldte.ERR_INTERNAL );
  end
  GP=F and trace("[HasRoom COMPARE]<%s:%s>KeyCount(%d) NodeListMax(%d)",
    MOD, meth, keyCount, nodeMax );
  if( keyCount >= nodeMax ) then
    list.append( sp.HasRoom, false );
    GP=F and trace("[HasRoom FALSE]<%s:%s>Level(%d) SP(%s)",
        MOD, meth, levelCount + 1, tostring( sp ));
  else
    list.append( sp.HasRoom, true );
    GP=F and trace("[HasRoom TRUE ]<%s:%s>Level(%d) SP(%s)",
        MOD, meth, levelCount + 1, tostring( sp ));
  end

  GP=E and trace("[EXIT]<%s:%s> SP(%s)", MOD, meth, tostring(sp) );
  return rc;
end -- updateSearchPath()

-- ======================================================================
-- listScan(): Scan a List
-- ======================================================================
-- Whether this list came from the Leaf or the Compact List, we'll search
-- thru it and look for matching items -- applying the FILTER on all objects
-- that match the key.
--
-- Parms:
-- (*) objectList
-- (*) startPosition:
-- (*) ldtMap:
-- (*) resultList:
-- (*) searchKey:
-- (*) flag: Termination criteria: key ~= val or key > val
-- Return: A, B, where A is the instruction and B is the return code
-- A: Instruction: 0 (SCAN_DONE==stop), 1 (SCAN_CONTINUE==continue scanning)
-- B: Error Code: B==0 ok.   B < 0 Error.
-- ======================================================================
local function
listScan(objectList, startPosition, ldtMap, resultList, searchKey, flag)
  local meth = "listScan()";
  local rc = 0;
  GP=E and trace("[ENTER]<%s:%s>StartPosition(%d) SearchKey(%s) flag(%d)",
        MOD, meth, startPosition, tostring( searchKey), flag);

  -- Linear scan of the LIST (binary search will come later), for each
  -- match, add to the resultList.
  local compareResult = 0;
  local uniqueKey = ldtMap[R_KeyUnique]; -- AS_TRUE or AS_FALSE.
  local scanStatus = SCAN_CONTINUE;
  local storeObject; -- the transformed User Object (what's stored).
  local liveObject; -- the untransformed storeObject.

  -- Later: Maybe .. Split the loop search into two -- atomic and map objects
  local listSize = list.size( objectList );
  -- We expect that the FIRST compare (at location "start") should be
  -- equal, and then potentially some number of objects after that (assuming
  -- it's NOT a unique key).  If unique, then we will just jump out on the
  -- next compare.
  GP=F and trace("[LIST SCAN]<%s:%s>Position(%d)", MOD, meth, startPosition);
  for i = startPosition, listSize, 1 do
    -- UnTransform the object, if needed.
    storeObject = objectList[i];
    if( G_UnTransform ~= nil ) then
      liveObject = G_UnTransform( storeObject );
    else
      liveObject = storeObject;
    end

    compareResult = objectCompare( ldtMap, searchKey, liveObject );
    if compareResult == CR_ERROR then
      warn("[WARNING]<%s:%s> Compare Error", MOD, meth );
      return 0, CR_ERROR; -- error result.
    end
    -- Equals is always good.  If we are doing a true range scan, then
    -- as long as the searchKey is LESS THAN the value, we're also good.
    GP=F and trace("[RANGE]<%s:%s>searchKey(%s) LiveObj(%s) CR(%s) FG(%d)",
      MOD, meth, tostring(searchKey),tostring(liveObject),
      tostring(compareResult), flag);

    if((compareResult == CR_EQUAL)or(compareResult == flag)) then
       GP=F and trace("[CR OK]<%s:%s> CR(%d))", MOD, meth, compareResult);
      -- This one qualifies -- save it in result -- if it passes the filter.
      local filterResult = liveObject;
      if( G_Filter ~= nil ) then
        filterResult = G_Filter( liveObject, G_FunctionArgs );
      end
      if( filterResult ~= nil ) then
        list.append( resultList, liveObject );
        filterPass = true;
      end

      GP=F and trace("[Scan]<%s:%s> Pos(%d) Key(%s) Obj(%s) FilterRes(%s)",
        MOD, meth, i, tostring(searchKey), tostring(liveObject),
        tostring(filterResult));

      -- If we're doing a RANGE scan, then we don't want to jump out, but
      -- if we're doing just a VALUE search (and it's unique), then we're 
      -- done and it's time to leave.
      if(uniqueKey == AS_TRUE and searchKey ~= nil and flag == CR_EQUAL) then
        scanStatus = SCAN_DONE;
        GP=F and trace("[BREAK]<%s:%s> SCAN DONE", MOD, meth);
        break;
      end
    else
      -- First non-equals (or non-range end) means we're done.
      GP=F and trace("[Scan:NON_MATCH]<%s:%s> Pos(%d) Key(%s) Obj(%s) CR(%d)",
        MOD, meth, i, tostring(searchKey), tostring(liveObject), compareResult);
      scanStatus = SCAN_DONE;
      break;
    end
  end -- for each item from startPosition to end

  local resultA = scanStatus;
  local resultB = ERR_OK; -- if we got this far, we're ok.

  GP=E and trace("[EXIT]<%s:%s> rc(%d) A(%s) B(%s) Result: Sz(%d) List(%s)",
    MOD, meth, rc, tostring(resultA), tostring(resultB),
    list.size(resultList), tostring(resultList));

  return resultA, resultB;
end -- listScan()

-- ======================================================================
-- scanByteArray(): Scan a Byte Array, gathering up all of the the
-- matching value(s) in the array.  Before an object can be compared,
-- it must be UN-TRANSFORMED from a binary form to a live object.
-- ======================================================================
-- Parms:
-- (*) byteArray: Packed array of bytes holding transformed objects
-- (*) startPosition: logical ITEM offset (not byte offset)
-- (*) ldtMap:
-- (*) resultList:
-- (*) searchKey:
-- (*) flag:
-- Return: A, B, where A is the instruction and B is the return code
-- A: Instruction: 0 (stop), 1 (continue scanning)
-- B: Error Code: B==0 ok.   B < 0 Error.
-- ======================================================================
local function scanByteArray(byteArray, startPosition, ldtMap, resultList,
                          searchKey, flag)
  local meth = "scanByteArray()";
  local rc = 0;
  GP=E and trace("[ENTER]<%s:%s>StartPosition(%s) SearchKey(%s)",
        MOD, meth, startPosition, tostring( searchKey));

  -- Linear scan of the ByteArray (binary search will come later), for each
  -- match, add to the resultList.
  local compareResult = 0;
  local uniqueKey = ldtMap[R_KeyUnique]; -- AS_TRUE or AS_FALSE;
  local scanStatus = SCAN_CONTINUE;

  -- >>>>>>>>>>>>>>>>>>>>>>>>> BINARY MODE <<<<<<<<<<<<<<<<<<<<<<<<<<<
    -- Do the BINARY (COMPACT BYTE ARRAY) page mode search here -- eventually
  GP=F and warn("[NOTICE!!]: <%s:%s> :BINARY MODE NOT YET IMPLEMENTED",
        MOD, meth, tostring(newStorageValue), tostring( resultList));
  return 0, ERR_GENERAL; -- TODO: Build this mode.

end -- scanByteArray()

-- ======================================================================
-- scanLeaf(): Scan a Leaf Node, gathering up all of the the matching
-- value(s) in the leaf node(s).
-- ======================================================================
-- Once we've searched a B+ Tree and found "The Place", then we have the
-- option of Scanning for values, Inserting new objects or deleting existing
-- objects.  This is the function for gathering up one or more matching
-- values from the leaf node(s) and putting them in the result list.
-- Notice that if there are a LOT Of values that match the search value,
-- then we might read a lot of leaf nodes.
--
-- Leaf Node Structure:
-- (*) TopRec digest
-- (*) Parent rec digest
-- (*) This Rec digest
-- (*) NEXT Leaf
-- (*) PREV Leaf
-- (*) Min value is implicitly index 1,
-- (*) Max value is implicitly at index (size of list)
-- (*) Beginning of last value
-- Parms:
-- (*) topRec: 
-- (*) leafSubRec:
-- (*) startPosition:
-- (*) ldtMap:
-- (*) resultList:
-- (*) searchKey:
-- (*) flag:
-- Return: A, B, where A is the instruction and B is the return code
-- A: Instruction: 0 (stop), 1 (continue scanning)
-- B: Error Code: B==0 ok.   B < 0 Error.
-- ======================================================================
-- NOTE: Need to pass in leaf Rec and Start Position -- because the
-- searchPath will be WRONG if we continue the search on a second page.
local function scanLeaf(topRec, leafSubRec, startPosition, ldtMap, resultList,
                          searchKey, flag)
  local meth = "scanLeaf()";
  local rc = 0;
  GP=E and trace("[ENTER]<%s:%s>StartPosition(%s) SearchKey(%s)",
        MOD, meth, startPosition, tostring( searchKey));

  -- Linear scan of the Leaf Node (binary search will come later), for each
  -- match, add to the resultList.
  -- And -- do not confuse binary search (the algorithm for searching the page)
  -- with "Binary Mode", which is how we will compact values into a byte array
  -- for objects that can be transformed into a fixed size object.
  local compareResult = 0;
  -- local uniqueKey = ldtMap[R_KeyUnique]; -- AS_TRUE or AS_FALSE;
  local scanStatus = SCAN_CONTINUE;
  local resultA = 0;
  local resultB = 0;

  GP=F and trace("[DEBUG]<%s:%s> Checking Store Mode(%s) (List or Binary?)",
    MOD, meth, tostring( ldtMap[M_StoreMode] ));

  if( ldtMap[M_StoreMode] == SM_BINARY ) then
    -- >>>>>>>>>>>>>>>>>>>>>>>>> BINARY MODE <<<<<<<<<<<<<<<<<<<<<<<<<<<
    GP=F and trace("[DEBUG]<%s:%s> BINARY MODE SCAN", MOD, meth );
    local byteArray = leafSubRec[LSR_BINARY_BIN];
    resultA, resultB = scanByteArray( byteArray, startPosition, ldtMap,
                        resultList, searchKey, flag);
  else
    -- >>>>>>>>>>>>>>>>>>>>>>>>>  LIST  MODE <<<<<<<<<<<<<<<<<<<<<<<<<<<
    GP=F and trace("[DEBUG]<%s:%s> LIST MODE SCAN", MOD, meth );
    -- Do the List page mode search here
    -- Later: Split the loop search into two -- atomic and map objects
    local objectList = leafSubRec[LSR_LIST_BIN];
    resultA, resultB = listScan(objectList, startPosition, ldtMap,
                  resultList, searchKey, flag);
  end -- else list mode

  -- ResultList goes last -- if long, it gets truncated.
  GP=E and trace("[EXIT]<%s:%s> rc(%d) A(%s) B(%s) RSz(%d) result(%s)", MOD,
    meth, rc, tostring(resultA), tostring(resultB),
    list.size(resultList), tostring(resultList));

  return resultA, resultB;
end -- scanLeaf()

-- ======================================================================
-- Get the tree node (record) the corresponds to the stated position.
-- ======================================================================
-- local function  getTreeNodeRec( src, topRec, ldtMap, digestList, position )
--   local digestString = tostring( digestList[position] );
--   -- local rec = aerospike:open_subrec( topRec, digestString );
--   local rec = openSubrec( src, topRec, digestString );
--   return rec;
-- end -- getTreeNodeRec()

-- ======================================================================
-- treeSearch()
-- ======================================================================
-- Search the tree (start with the root and move down). 
-- Remember the search path from root to leaf (and positions in each
-- node) so that insert, Scan and Delete can use this to set their
-- starting positions.
-- Parms:
-- (*) src: subrecContext: The pool of open subrecs
-- (*) topRec: The top level Aerospike Record
-- (*) sp: searchPath: A list of maps that describe each level searched
-- (*) ldtMap: 
-- (*) searchKey: If null, compares LESS THAN everything
-- Return: ST_FOUND(0) or ST_NOTFOUND(-1)
-- And, implicitly, the updated searchPath Object.
-- ======================================================================
local function
treeSearch( src, topRec, sp, ldtCtrl, searchKey )
  local meth = "treeSearch()";
  local rc = 0;
  GP=E and trace("[ENTER]<%s:%s> searchKey(%s) ldtSummary(%s)",
      MOD, meth, tostring(searchKey), ldtSummaryString(ldtCtrl) );

  -- Extract the property map and control map from the ldt bin list.
  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];

  local treeLevels = ldtMap[R_TreeLevel];

  GP=F and trace("[DEBUG]<%s:%s>searchKey(%s) ldtSummary(%s) CMap(%s) PMap(%s)",
      MOD, meth, tostring(searchKey), ldtSummaryString(ldtCtrl),
      tostring(ldtMap), tostring(propMap) );
  -- Start the loop with the special Root, then drop into each successive
  -- inner node level until we get to a LEAF NODE.  We search the leaf node
  -- differently than the inner (and root) nodes, since they have OBJECTS
  -- and not keys.  To search a leaf we must compute the key (from the object)
  -- before we do the compare.
  local keyList = ldtMap[R_RootKeyList];
  local keyCount = list.size( keyList );
  local objectList = nil;
  local objectCount = 0;
  local digestList = ldtMap[R_RootDigestList];
  local position = 0;
  local nodeRec = topRec;
  local nodeCtrlMap;
  local resultMap;
  local digestString;

  trace("\n\n >> ABOUT TO SEARCH TREE -- Starting with ROOT!!!! \n\n");

  for i = 1, treeLevels, 1 do
     GP=F and trace("\n\n >>>>>>>  SEARCH Loop TOP  <<<<<<<<< \n\n");
     GP=F and trace("[DEBUG]<%s:%s>Loop Iteration(%d) Lvls(%d)",
       MOD, meth, i, treeLevels);
     GP=F and trace("[TREE SRCH] it(%d) Lvls(%d) KList(%s) DList(%s) OList(%s)",
       i, treeLevels, tostring(keyList), tostring(digestList),
       tostring(objectList));
    if( i < treeLevels ) then
      -- It's a root or node search -- so search the keys
      GP=F and trace("[DEBUG]<%s:%s> UPPER NODE Search", MOD, meth );
      position = searchKeyList( ldtMap, keyList, searchKey );
      if( position < 0 ) then
        warn("[ERROR]<%s:%s> searchKeyList Problem", MOD, meth );
        error( ldte.ERR_INTERNAL );
      end
      if( position == 0 ) then
        warn("[ERROR]<%s:%s> searchKeyList Problem:Position ZERO", MOD, meth );
        error( ldte.ERR_INTERNAL );
      end
      updateSearchPath(sp,propMap,ldtMap,nodeRec,position,keyCount );

      -- Get ready for the next iteration.  If the next level is an inner node,
      -- then populate our keyList and nodeCtrlMap.
      -- If the next level is a leaf, then populate our ObjectList and LeafMap.
      -- Remember to get the STRING version of the digest in order to
      -- call "open_subrec()" on it.
      GP=F and trace("[DEBUG]Opening Digest Pos(%d) DList(%s) for NextLevel",
        position, tostring( digestList ));

      digestString = tostring( digestList[position] );
      GP=F and trace("[DEBUG]<%s:%s> Checking Next Level", MOD, meth );
      -- NOTE: we're looking at the NEXT level (tl - 1) and we must be LESS
      -- than that to be an inner node.
      if( i < (treeLevels - 1) ) then
        -- Next Node is an Inner Node. 
        GP=F and trace("[Opening NODE Subrec]<%s:%s> Digest(%s) Pos(%d)",
            MOD, meth, digestString, position );
        nodeRec = ldt_common.openSubRec( src, topRec, digestString );
        GP=F and trace("[Open Inner Node Results]<%s:%s>nodeRec(%s)",
          MOD, meth, tostring(nodeRec));
        nodeCtrlMap = nodeRec[NSR_CTRL_BIN];
        propMap = nodeRec[SUBREC_PROP_BIN];
        GP=F and trace("[DEBUG]<%s:%s> NEXT NODE: INNER NODE: Summary(%s)",
            MOD, meth, nodeSummaryString( nodeRec ));
        keyList = nodeRec[NSR_KEY_LIST_BIN];
        keyCount = list.size( keyList );
        digestList = nodeRec[NSR_DIGEST_BIN]; 
        GP=F and trace("[DEBUG]<%s:%s> NEXT NODE: Digests(%s) Keys(%s)",
            MOD, meth, tostring( digestList ), tostring( keyList ));
      else
        -- Next Node is a Leaf
        GP=F and trace("[Opening Leaf]<%s:%s> Digest(%s) Pos(%d) TreeLevel(%d)",
          MOD, meth, digestString, position, i+1);
        nodeRec = ldt_common.openSubRec( src, topRec, digestString );
        GP=F and trace("[Open Leaf Results]<%s:%s>nodeRec(%s)",
          MOD,meth,tostring(nodeRec));
        propMap = nodeRec[SUBREC_PROP_BIN];
        nodeCtrlMap = nodeRec[LSR_CTRL_BIN];
        GP=F and trace("[DEBUG]<%s:%s> NEXT NODE: LEAF NODE: Summary(%s)",
            MOD, meth, leafSummaryString( nodeRec ));
        objectList = nodeRec[LSR_LIST_BIN];
        objectCount = list.size( objectList );
      end
    else
      -- It's a leaf search -- so search the objects.  Note that objectList
      -- and objectCount were set on the previous loop iteration.
      GP=F and trace("[DEBUG]<%s:%s> LEAF NODE Search", MOD, meth );
      resultMap = searchObjectList( ldtMap, objectList, searchKey );
      if( resultMap.Status == 0 ) then
        GP=F and trace("[DEBUG]<%s:%s> LEAF Search Result::Pos(%d) Cnt(%d)",
          MOD, meth, resultMap.Position, objectCount);
        updateSearchPath( sp, propMap, ldtMap, nodeRec,
                  resultMap.Position, objectCount );
      else
        GP=F and trace("[SEARCH ERROR]<%s:%s> LeafSrch Result::Pos(%d) Cnt(%d)",
          MOD, meth, resultMap.Position, keyCount);
      end
    end -- if node else leaf.
  end -- end for each tree level

  if( resultMap ~= nil and resultMap.Status == 0 and resultMap.Found == true )
  then
    position = resultMap.Position;
  else
    position = 0;
  end

  if position > 0 then
    rc = ST_FOUND;
  else
    rc = ST_NOTFOUND;
  end

  GP=E and trace("[EXIT]<%s:%s>RC(%d) SearchKey(%s) ResMap(%s) SearchPath(%s)",
      MOD,meth, rc, tostring(searchKey),tostring(resultMap),tostring(sp));

  return rc;
end -- treeSearch()

-- ======================================================================
-- Populate this leaf after a leaf split.
-- Parms:
-- (*) newLeafSubRec
-- (*) objectList
-- ======================================================================
local function populateLeaf( src, leafSubRec, objectList )
  local meth = "populateLeaf()";
  local rc = 0;
  GP=E and trace("[ENTER]<%s:%s>ObjList(%s)",MOD,meth,tostring(objectList));

  local propMap    = leafSubRec[SUBREC_PROP_BIN]
  local leafMap    = leafSubRec[LSR_CTRL_BIN];
  leafSubRec[LSR_LIST_BIN] = objectList;
  local count = list.size( objectList );
  leafMap[LF_ListEntryCount] = count;
  leafMap[LF_ListEntryTotal] = count;

  leafSubRec[LSR_CTRL_BIN] = leafMap;
  -- Call udpate to mark the SubRec as dirty, and to force the write if we
  -- are in "early update" mode. Close will happen at the end of the Lua call.
  ldt_common.updateSubRec( src, leafSubRec );

  GP=E and trace("[EXIT]<%s:%s> rc(%s)", MOD, meth, tostring(rc) );
  return rc;
end -- populateLeaf()

-- ======================================================================
-- listInsert()
-- General List Insert function that can be used to insert
-- keys, digests or objects.
-- ======================================================================
local function listInsert( myList, newValue, position )
  local meth = "listInsert()";
  GP=E and trace("[ENTER]<%s:%s>List(%s) ", MOD, meth, tostring(myList));

--  GP=E and trace("[ENTER]<%s:%s>List(%s) size(%d) Value(%s) Position(%d)", MOD,
--  meth, tostring(myList), list.size(myList), tostring(newValue), position );
  
  local listSize = list.size( myList );
  if( position > listSize ) then
    -- Just append to the list
    list.append( myList, newValue );
    GP=F and trace("[MYLIST APPEND]<%s:%s> Appended item(%s) to list(%s)",
      MOD, meth, tostring(newValue), tostring(myList) );
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
    GP=F and trace("[MYLIST TRANSFER]<%s:%s> listSize(%d) position(%d)",
      MOD, meth, listSize, position );
    local endValue = myList[listSize];
    list.append( myList, endValue );
    for i = (listSize - 1), position, -1  do
      myList[i+1] = myList[i];
    end -- for()
    myList[position] = newValue;
  end

  GP=E and trace("[EXIT]<%s:%s> Appended(%s) to list(%s)", MOD, meth,
    tostring(newValue), tostring(myList));

  return 0;
end -- listInsert()

-- ======================================================================
-- leafInsert()
-- Use the search position to mark the location where we have to make
-- room for the new value.
-- If we're at the end, we just append to the list.
-- Parms:
-- (*) src: Sub-Rec Context
-- (*) topRec: Primary Record
-- (*) leafSubRec: the leaf subrecord
-- (*) ldtMap: LDT Control: needed for key type and storage mode
-- (*) newKey: Search Key for newValue
-- (*) newValue: Object to be inserted.
-- (*) position: If non-zero, then it's where we insert. Otherwise, we search
-- ======================================================================
local function
leafInsert(src, topRec, leafSubRec, ldtMap, newKey, newValue, position)
  local meth = "leafInsert()";
  local rc = 0;
  GP=E and trace("[ENTER]<%s:%s> key(%s) value(%s) ldtMap(%s)",
    MOD, meth, tostring(newKey), tostring(newValue), tostring(ldtMap));

  GP=F and trace("[NOTICE!]<%s:%s>Using LIST MODE ONLY:No Binary Support (yet)",
    MOD, meth );

  local objectList = leafSubRec[LSR_LIST_BIN];
  local leafMap =  leafSubRec[LSR_CTRL_BIN];

  if( position == 0 ) then
    GP=F and trace("[INFO]<%s:%s>Position is ZERO:must Search for position",
      MOD, meth );
    local resultMap = searchObjectList( ldtMap, objectList, newKey );
    position = resultMap.Position;
  end

  if( position <= 0 ) then
    warn("[ERROR]<%s:%s> Search Path Position is wrong", MOD, meth );
    error( ldte.ERR_INTERNAL );
  end

  -- Move values around, if necessary, to put newValue in a "position"
  rc = listInsert( objectList, newValue, position );

  -- Update Counters
  local itemCount = leafMap[LF_ListEntryCount];
  leafMap[LF_ListEntryCount] = itemCount + 1;
  local totalCount = leafMap[LF_ListEntryTotal];
  leafMap[LF_ListEntryTotal] = totalCount + 1;

  leafSubRec[LSR_LIST_BIN] = objectList;
  -- Call udpate to mark the SubRec as dirty, and to force the write if we
  -- are in "early update" mode. Close will happen at the end of the Lua call.
  ldt_common.updateSubRec( src, leafSubRec );

  GP=E and trace("[EXIT]<%s:%s> rc(%s)", MOD, meth, tostring(rc) );
  return rc;
end -- leafInsert()

-- ======================================================================
-- getNodeSplitPosition()
-- Find the right place to split the B+ Tree Inner Node (or Root)
-- TODO: @TOBY: Maybe find a more optimal split position
-- Right now this is a simple arithmethic computation (split the leaf in
-- half).  This could change to split at a more convenient location in the
-- leaf, especially if duplicates are involved.  However, that presents
-- other problems, so we're doing it the easy way at the moment.
-- Parms:
-- (*) ldtMap: main control map
-- (*) keyList: the key list in the node
-- (*) nodePosition: the place in the key list for the new insert
-- (*) newKey: The new value to be inserted
-- ======================================================================
local function getNodeSplitPosition( ldtMap, keyList, nodePosition, newKey )
  local meth = "getNodeSplitPosition()";
  GP=E and trace("[ENTER]<%s:%s> ", MOD, meth );
  GP=F and trace("[NOTICE!!]<%s:%s> Using Rough Approximation", MOD, meth );

  -- This is only an approximization
  local listSize = list.size( keyList );
  local result = (listSize / 2) + 1; -- beginning of 2nd half, or middle

  GP=E and trace("[EXIT]<%s:%s> result(%d)", MOD, meth, result );
  return result;
end -- getNodeSplitPosition

-- ======================================================================
-- getLeafSplitPosition()
-- Find the right place to split the B+ Tree Leaf
-- TODO: @TOBY: Maybe find a more optimal split position
-- Right now this is a simple arithmethic computation (split the leaf in
-- half).  This could change to split at a more convenient location in the
-- leaf, especially if duplicates are involved.  However, that presents
-- other problems, so we're doing it the easy way at the moment.
-- Parms:
-- (*) ldtMap: main control map
-- (*) objList: the object list in the leaf
-- (*) leafPosition: the place in the obj list for the new insert
-- (*) newValue: The new value to be inserted
-- ======================================================================
local function getLeafSplitPosition( ldtMap, objList, leafPosition, newValue )
  local meth = "getLeafSplitPosition()";
  GP=E and trace("[ENTER]<%s:%s> ", MOD, meth );
  GP=F and trace("[NOTICE!!]<%s:%s> Using Rough Approximation", MOD, meth );

  -- This is only an approximization
  local listSize = list.size( objList );
  local result = (listSize / 2) + 1; -- beginning of 2nd half, or middle

  GP=E and trace("[EXIT]<%s:%s> result(%d)", MOD, meth, result );
  return result;
end -- getLeafSplitPosition

-- ======================================================================
-- nodeInsert()
-- Insert a new key,digest pair into the node.  We pass in the actual
-- lists, not the nodeRec, so that we can treat Nodes and the Root in
-- the same way.  Thus, it is up to the caller to update the node (or root)
-- information, other than the list update, which is what we do here.
-- Parms:
-- (*) keyList:
-- (*) digestList:
-- (*) key:
-- (*) digest:
-- (*) position:
-- ======================================================================
local function nodeInsert( keyList, digestList, key, digest, position )
  local meth = "nodeInsert()";
  local rc = 0;

  GP=E and trace("[ENTER]<%s:%s> KL(%s) DL(%s) key(%s) D(%s) P(%d)",
    MOD, meth, tostring(keyList), tostring(digestList), tostring(key),
    tostring(digest), position);

  -- If the position is ZERO, then that means we'll have to do another search
  -- here to find the right spot.  Usually, position == 0 means we have
  -- to find the new spot after a split.  Sure, that could be calculated,
  -- but this is safer -- for now.
  if( position == 0 ) then
    GP=F and trace("[INFO]<%s:%s>Position is ZERO:must Search for position", MOD, meth );
    position = searchKeyList( ldtMap, keyList, key );
  end

  -- Move values around, if necessary, to put key and digest in "position"
  rc = listInsert( keyList, key, position );
  rc = listInsert( digestList, digest, position );

  GP=E and trace("[EXIT]<%s:%s> rc(%s)", MOD, meth, tostring(rc) );
  return rc;

end -- nodeInsert()

-- ======================================================================
-- Populate this inner node after a child split.
-- Parms:
-- (*) nodeSubRec
-- (*) keyList
-- (*) digestList
-- ======================================================================
local function  populateNode( nodeSubRec, keyList, digestList)
  local meth = "populateNode()";
  local rc = 0;
  GP=E and trace("[ENTER]<%s:%s> keyList(%s) digestList(%s)",
    MOD, meth, tostring(keyList), tostring(digestList));

  local nodeItemCount = list.size( keyList );
  nodeSubRec[NSR_KEY_LIST_BIN] = keyList;
  nodeSubRec[NSR_DIGEST_BIN] = digestList;

  local nodeCtrlMap = nodeSubRec[NSR_CTRL_BIN];
  nodeCtrlMap[ND_ListEntryCount] = nodeItemCount;
  nodeCtrlMap[ND_ListEntryTotal] = nodeItemCount;
  nodeSubRec[NSR_CTRL_BIN] = nodeCtrlMap;

  GP=E and trace("[EXIT]<%s:%s> rc(%s)", MOD, meth, tostring(rc) );
  return rc;
end -- populateNode()

-- ======================================================================
-- Create a new Inner Node Page and initialize it.
-- ======================================================================
-- createNodeRec( Interior Tree Nodes )
-- ======================================================================
-- Set the values in an Inner Tree Node Control Map and Key/Digest Lists.
-- There are potentially FIVE bins in an Interior Tree Node Record:
--
--    >>>>>>>>>>>>>12345678901234<<<<<< (14 char limit for Bin Names) 
-- (1) nodeSubRec['NsrControlBin']: The control Map (defined here)
-- (2) nodeSubRec['NsrKeyListBin']: The Data Entry List (when in list mode)
-- (3) nodeSubRec['NsrBinaryBin']: The Packed Data Bytes (when in Binary mode)
-- (4) nodeSubRec['NsrDigestBin']: The Data Entry List (when in list mode)
-- Pages are either in "List" mode or "Binary" mode (the whole tree is in
-- one mode or the other), so the record will employ only three fields.
-- Either Bins 1,2,4 or Bins 1,3,4.
--
-- NOTES:
-- (1) For the Digest Bin -- we'll be in LIST MODE for debugging, but
--     in BINARY mode for production.
-- (2) For the Digests (when we're in binary mode), we could potentially
-- save some space by NOT storing the Lock bits and the Partition Bits
-- since we force all of those to be the same,
-- we know they are all identical to the top record.  So, that would save
-- us 4 bytes PER DIGEST -- which adds up for 50 to 100 entries.
-- We would use a transformation method to transform a 20 byte value into
-- and out of a 16 byte value.
--
-- ======================================================================
-- Parms:
-- (*) src: subrecContext: The pool of open subrecords
-- (*) topRec: The main AS Record holding the LDT
-- (*) ldtCtrl: Main LDT Control Structure
-- Contents of a Node Record:
-- (1) SUBREC_PROP_BIN: Main record Properties go here
-- (2) NSR_CTRL_BIN:    Main Node Control structure
-- (3) NSR_KEY_LIST_BIN: Key List goes here
-- (4) NSR_DIGEST_BIN: Digest List (or packed binary) goes here
-- (5) NSR_BINARY_BIN:  Packed Binary Array (if used) goes here
-- ======================================================================
local function createNodeRec( src, topRec, ldtCtrl )
  local meth = "createNodeRec()";
  GP=E and trace("[ENTER]<%s:%s> ", MOD, meth );

  -- Extract the property map and control map from the ldt bin list.
  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];

  -- Create the Aerospike Sub-Record, initialize the Bins (Ctrl, List).
  -- The createSubRec() handles the record type and the SRC.
  -- It also kicks out with an error if something goes wrong.
  local nodeSubRec = ldt_common.createSubRec( src, topRec, ldtCtrl, RT_SUB );
  local nodePropMap = nodeSubRec[SUBREC_PROP_BIN];
  local nodeCtrlMap = map();

  -- Notes:
  -- (1) Item Count is implicitly the KeyList size
  -- (2) All Max Limits, Key sizes and Obj sizes are in the root map
  nodeCtrlMap[ND_ListEntryCount] = 0;  -- Current # of entries in the node list
  nodeCtrlMap[ND_ListEntryTotal] = 0;  -- Total # of slots used in the node list
  nodeCtrlMap[ND_ByteEntryCount] = 0;  -- Bytes used (if in binary mode)

  -- Store the new maps in the record.
  nodeSubRec[SUBREC_PROP_BIN] = nodePropMap;
  nodeSubRec[NSR_CTRL_BIN]    = nodeCtrlMap;
  nodeSubRec[NSR_KEY_LIST_BIN] = list(); -- Holds the keys
  nodeSubRec[NSR_DIGEST_BIN] = list(); -- Holds the Digests -- the Rec Ptrs

  -- NOTE: The SubRec business is Handled by subRecCreate().
  -- Also, If we had BINARY MODE working for inner nodes, we would initialize
  -- the Key BYTE ARRAY here.  However, the real savings would be in the
  -- leaves, so it may not be much of an advantage to use binary mode in nodes.

  GP=E and trace("[EXIT]<%s:%s> rc(%s)", MOD, meth, tostring(rc) );
  return nodeSubRec;
end -- createNodeRec()


-- ======================================================================
-- splitRootInsert()
-- Split this ROOT node, because after a leaf split and the upward key
-- propagation, there's no room in the ROOT for the additional key.
-- Root Split is different any other node split for several reasons:
-- (1) The Root Key and Digests Lists are part of the control map.
-- (2) The Root stays the root.  We create two new children (inner nodes)
--     that become a new level in the tree.
-- Parms:
-- (*) src: SubRec Context (for looking up open subrecs)
-- (*) topRec:
-- (*) sp: SearchPath (from the initial search)
-- (*) ldtCtrl:
-- (*) key:
-- (*) digest:
-- ======================================================================
local function splitRootInsert( src, topRec, sp, ldtCtrl, key, digest )
  local meth = "splitRootInsert()";
  local rc = 0;
  GP=E and trace("[ENTER]<%s:%s> topRec(%s) SRC(%s) SP(%s) LDT(%s) Key(%s) ",
    MOD, meth,tostring(topRec), tostring(src), tostring(sp), tostring(key),
    tostring(digest));
  
  GP=F and trace("\n\n <><H><> !!! SPLIT ROOT !!! Key(%s)<><W><> \n",
    tostring( key ));

  -- Extract the property map and control map from the ldt bin list.
  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];
  local ldtBinName = propMap[PM_BinName];

  local rootLevel = 1;
  local rootPosition = sp.PositionList[rootLevel];

  local keyList = ldtMap[R_RootKeyList];
  local digestList = ldtMap[R_RootDigestList];

  -- Calculate the split position and the key to propagate up to parent.
  local splitPosition =
      getNodeSplitPosition( ldtMap, keyList, rootPosition, key );
  -- local splitKey = getKeyValue( ldtMap, keyList[splitPosition] );
  local splitKey = keyList[splitPosition];

  GP=F and trace("[STATUS]<%s:%s> Take and Drop::Pos(%d)Key(%s) Digest(%s)",
    MOD, meth, splitPosition, tostring(keyList), tostring(digestList));

    -- Splitting a node works as follows.  The node is split into a left
    -- piece, a right piece, and a center value that is propagated up to
    -- the parent (in this case, root) node.
    --              +---+---+---+---+---+
    -- KeyList      |111|222|333|444|555|
    --              +---+---+---+---+---+
    -- DigestList   A   B   C   D   E   F
    --
    --                      +---+
    -- New Parent Element   |333|
    --                      +---+
    --                     /     \
    --              +---+---+   +---+---+
    -- KeyList      |111|222|   |444|555|
    --              +---+---+   +---+---+
    -- DigestList   A   B   C   D   E   F
    --
  -- Our List operators :
  -- (*) list.take (take the first N elements) 
  -- (*) list.drop (drop the first N elements, and keep the rest) 
  -- will let us split the current Root node list into two node lists.
  -- We propagate up the split key (the new root value) and the two
  -- new inner node digests.
  local leftKeyList  = list.take( keyList, splitPosition - 1 );
  local rightKeyList = list.drop( keyList, splitPosition  );

  local leftDigestList  = list.take( digestList, splitPosition );
  local rightDigestList = list.drop( digestList, splitPosition );

  GP=F and trace("\n[DEBUG]<%s:%s>LKey(%s) LDig(%s) SKey(%s) RKey(%s) RDig(%s)",
    MOD, meth, tostring(leftKeyList), tostring(leftDigestList),
    tostring( splitKey ), tostring(rightKeyList), tostring(rightDigestList) );

  -- Create two new Child Inner Nodes -- that will be the new Level 2 of the
  -- tree.  The root gets One Key and Two Digests.
  local leftNodeRec  = createNodeRec( src, topRec, ldtCtrl );
  local rightNodeRec = createNodeRec( src, topRec, ldtCtrl );

  local leftNodeDigest  = record.digest( leftNodeRec );
  local rightNodeDigest = record.digest( rightNodeRec );

  -- This is a different order than the splitLeafInsert, but before we
  -- populate the new child nodes with their new lists, do the insert of
  -- the new key/digest value now.
  -- Figure out WHICH of the two nodes that will get the new key and
  -- digest. Insert the new value.
  -- Compare against the SplitKey -- if less, insert into the left node,
  -- and otherwise insert into the right node.
  local compareResult = keyCompare( key, splitKey );
  if( compareResult == CR_LESS_THAN ) then
    -- We choose the LEFT Node -- but we must search for the location
    nodeInsert( leftKeyList, leftDigestList, key, digest, 0 );
  elseif( compareResult >= CR_EQUAL  ) then -- this works for EQ or GT
    -- We choose the RIGHT (new) Node -- but we must search for the location
    nodeInsert( rightKeyList, rightDigestList, key, digest, 0 );
  else
    -- We got some sort of goofy error.
    warn("[ERROR]<%s:%s> Compare Error(%d)", MOD, meth, compareResult );
    error( ldte.ERR_INTERNAL );
  end

  -- Populate the new nodes with their Key and Digest Lists
  populateNode( leftNodeRec, leftKeyList, leftDigestList);
  populateNode( rightNodeRec, rightKeyList, rightDigestList);
  -- Call udpate to mark the SubRec as dirty, and to force the write if we
  -- are in "early update" mode. Close will happen at the end of the Lua call.
  ldt_common.updateSubRec( src, leftNodeRec );
  ldt_common.updateSubRec( src, rightNodeRec );

  -- Replace the Root Information with just the split-key and the
  -- two new child node digests (much like first Tree Insert).
  local keyList = list();
  list.append( keyList, splitKey );
  local digestList = list();
  list.append( digestList, leftNodeDigest );
  list.append( digestList, rightNodeDigest );

  -- The new tree is now one level taller
  local treeLevel = ldtMap[R_TreeLevel];
  ldtMap[R_TreeLevel] = treeLevel + 1;

  -- Update the Main control map with the new root lists.
  ldtMap[R_RootKeyList] = keyList;
  ldtMap[R_RootDigestList] = digestList;

  GP=E and trace("[EXIT]<%s:%s> rc(%s)", MOD, meth, tostring(rc) );
  return rc;
end -- splitRootInsert()

-- ======================================================================
-- splitNodeInsert()
-- Split this parent node, because after a leaf split and the upward key
-- propagation, there's no room in THIS node for the additional key.
-- Special case is "Root Split" -- and that's handled by the function above.
-- Just like the leaf split situation -- we have to be careful about 
-- duplicates.  We don't want to split in the middle of a set of duplicates,
-- if we can possibly avoid it.  If the WHOLE node is the same key value,
-- then we can't avoid it.
-- Parms:
-- (*) src: SubRec Context (for looking up open subrecs)
-- (*) topRec:
-- (*) sp: SearchPath (from the initial search)
-- (*) ldtCtrl:
-- (*) key:
-- (*) digest:
-- (*) level:
-- ======================================================================
local function splitNodeInsert( src, topRec, sp, ldtCtrl, key, digest, level )
  local meth = "splitNodeInsert()";
  local rc = 0;
  GP=E and trace("[ENTER]<%s:%s> SRC(%s) SP(%s) LDT(%s) Key(%s) Lvl(%d)",
    MOD, meth, tostring(src), tostring(sp), tostring(key), tostring(digest),
    level );
  
  if( level == 1 ) then
    -- Special Split -- Root is handled differently.
    rc = splitRootInsert( src, topRec, sp, ldtCtrl, key, digest );
  else
    -- Ok -- "Regular" Inner Node Split Insert.
    -- We will split this inner node, use the existing node as the new
    -- "rightNode" and the newly created node as the new "LeftNode".
    -- We will insert the "splitKey" and the new leftNode in the parent.
    -- And, if the parent has no room, we'll recursively call this function
    -- to propagate the insert up the tree.  ((I hope recursion doesn't
    -- blow up the Lua environment!!!!  :-) ).

    GP=F and trace("\n\n <><!><> !!! SPLIT INNER NODE !!! <><E><> \n\n");

    -- Extract the property map and control map from the ldt bin list.
    local propMap = ldtCtrl[1];
    local ldtMap  = ldtCtrl[2];
    local ldtBinName = propMap[PM_BinName];

    local nodePosition = sp.PositionList[level];
    local nodeSubRecDigest = sp.DigestList[level];
    local nodeSubRec = sp.RecList[level];

    -- Open the Node get the map, Key and Digest Data
    local nodePropMap    = nodeSubRec[SUBREC_PROP_BIN];
    GP=F and trace("\n[DUMP]<%s:%s>Node Prop Map(%s)", MOD, meth, tostring(nodePropMap));

    local nodeCtrlMap    = nodeSubRec[NSR_CTRL_BIN];
    local keyList    = nodeSubRec[NSR_KEY_LIST_BIN];
    local digestList = nodeSubRec[NSR_DIGEST_BIN];

    -- Calculate the split position and the key to propagate up to parent.
    local splitPosition =
        getNodeSplitPosition( ldtMap, keyList, nodePosition, key );
    -- We already have a key list -- don't need to "extract".
    -- local splitKey = getKeyValue( ldtMap, keyList[splitPosition] );
    local splitKey = keyList[splitPosition];

    GP=F and trace("\n[DUMP]<%s:%s> Take and Drop:: Map(%s) KeyList(%s) DigestList(%s)",
      MOD, meth, tostring(nodeCtrlMap), tostring(keyList), tostring(digestList));

    -- Splitting a node works as follows.  The node is split into a left
    -- piece, a right piece, and a center value that is propagated up to
    -- the parent node.
    --              +---+---+---+---+---+
    -- KeyList      |111|222|333|444|555|
    --              +---+---+---+---+---+
    -- DigestList   A   B   C   D   E   F
    --
    --                      +---+
    -- New Parent Element   |333|
    --                      +---+
    --                     /     \
    --              +---+---+   +---+---+
    -- KeyList      |111|222|   |444|555|
    --              +---+---+   +---+---+
    -- DigestList   A   B   C   D   E   F
    --
    -- Our List operators :
    -- (*) list.take (take the first N elements) 
    -- (*) list.drop (drop the first N elements, and keep the rest) 
    -- will let us split the current Node list into two Node lists.
    -- We will always propagate up the new Key and the NEW left page (digest)
    local leftKeyList  = list.take( keyList, splitPosition - 1 );
    local rightKeyList = list.drop( keyList, splitPosition );

    local leftDigestList  = list.take( digestList, splitPosition );
    local rightDigestList = list.drop( digestList, splitPosition );

    GP=F and trace("\n[DEBUG]<%s:%s>: LeftKey(%s) LeftDig(%s) RightKey(%s) RightDig(%s)",
      MOD, meth, tostring(leftKeyList), tostring(leftDigestList),
      tostring(rightKeyList), tostring(rightDigestList) );

    local rightNodeRec = nodeSubRec; -- our new name for the existing node
    local leftNodeRec = createNodeRec( src, topRec, ldtCtrl );
    local leftNodeDigest = record.digest( leftNodeRec );

    -- This is a different order than the splitLeafInsert, but before we
    -- populate the new child nodes with their new lists, do the insert of
    -- the new key/digest value now.
    -- Figure out WHICH of the two nodes that will get the new key and
    -- digest. Insert the new value.
    -- Compare against the SplitKey -- if less, insert into the left node,
    -- and otherwise insert into the right node.
    local compareResult = keyCompare( key, splitKey );
    if( compareResult == CR_LESS_THAN ) then
      -- We choose the LEFT Node -- but we must search for the location
      nodeInsert( leftKeyList, leftDigestList, key, digest, 0 );
    elseif( compareResult >= CR_EQUAL  ) then -- this works for EQ or GT
      -- We choose the RIGHT (new) Node -- but we must search for the location
      nodeInsert( rightKeyList, rightDigestList, key, digest, 0 );
    else
      -- We got some sort of goofy error.
      warn("[ERROR]<%s:%s> Compare Error(%d)", MOD, meth, compareResult );
      error( ldte.ERR_INTERNAL );
    end

    -- Populate the new nodes with their Key and Digest Lists
    populateNode( leftNodeRec, leftKeyList, leftDigestList);
    populateNode( rightNodeRec, rightKeyList, rightDigestList);
  -- Call udpate to mark the SubRec as dirty, and to force the write if we
  -- are in "early update" mode. Close will happen at the end of the Lua call.
  ldt_common.updateSubRec( src, leftNodeRec );
  ldt_common.updateSubRec( src, rightNodeRec );

  -- Update the parent node with the new Node information.  It is the job
  -- of this method to either split the parent or do a straight insert.
    
    GP=F and trace("\n\n CALLING INSERT PARENT FROM SPLIT NODE: Key(%s)\n",
      tostring(splitKey));

    insertParentNode(src, topRec, sp, ldtCtrl, splitKey,
      leftNodeDigest, level - 1 );
  end -- else regular (non-root) node split

  GP=F and trace("[EXIT]<%s:%s> rc(%s)", MOD, meth, tostring(rc) );
  return rc;

end -- splitNodeInsert()

-- ======================================================================
-- After a leaf split or a node split, this parent node gets a new child
-- value and digest.  This node might be the root, or it might be an
-- inner node.  If we have to split this node, then we'll perform either
-- a node split or a ROOT split (ugh) and recursively call this method
-- to insert one level up.  Of course, Root split is a special case, because
-- the root node is basically ensconced inside of the LDT control map.
-- Parms:
-- (*) src: The SubRec Context (holds open subrecords).
-- (*) topRec: The main record
-- (*) sp: the searchPath structure
-- (*) ldtCtrl: the main control structure
-- (*) key: the new key to be inserted
-- (*) digest: The new digest to be inserted
-- (*) level: The current level in searchPath of this node
-- ======================================================================
-- NOTE: This function is FORWARD-DECLARED, so it does NOT get a "local"
-- declaration here.
-- ======================================================================
function insertParentNode(src, topRec, sp, ldtCtrl, key, digest, level)
  local meth = "insertParentNode()";
  local rc = 0;
  GP=E and trace("[ENTER]<%s:%s> SP(%s) Key(%s) Dig(%s) Level(%d)",
    MOD, meth, tostring(sp), tostring(key), tostring(digest), level );
  GP=F and trace("\n[DUMP]<%s> LDT(%s)", meth, ldtSummaryString(ldtCtrl) );

  GP=F and trace("\n\n STARTING INTO INSERT PARENT NODE \n\n");

  -- Extract the property map and control map from the ldt bin list.
  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];
  local ldtBinName = propMap[PM_BinName];

  -- Check the tree level.  If it's the root, we access the node data
  -- differently from a regular inner tree node.
  local listMax;
  local keyList;
  local digestList;
  local position = sp.PositionList[level];
  local nodeSubRec = nil;
  GP=F and trace("[DEBUG]<%s:%s> Lvl(%d) Pos(%d)", MOD, meth, level, position);
  if( level == 1 ) then
    -- Get the control and list data from the Root Node
    listMax    = ldtMap[R_RootListMax];
    keyList    = ldtMap[R_RootKeyList];
    digestList = ldtMap[R_RootDigestList];
  else
    -- Get the control and list data from a regular inner Tree Node
    nodeSubRec = sp.RecList[level];
    if( nodeSubRec == nil ) then
      warn("[ERROR]<%s:%s> Nil NodeRec from SearchPath. Level(%s)",
        MOD, meth, tostring(level));
      error( ldte.ERR_INTERNAL );
    end
    listMax    = ldtMap[R_NodeListMax];
    keyList    = nodeSubRec[NSR_KEY_LIST_BIN];
    digestList = nodeSubRec[NSR_DIGEST_BIN];
  end

  -- If there's room in this node, then this is easy.  If not, then
  -- it's a complex split and propagate.
  if( sp.HasRoom[level] == true ) then
    -- Regular node insert
    rc = nodeInsert( keyList, digestList, key, digest, position );
    -- If it's a node, then we have to re-assign the list to the subrec
    -- fields -- otherwise, the change may not take effect.
    if( rc == 0 ) then
      if( level > 1 ) then
        nodeSubRec[NSR_KEY_LIST_BIN] = keyList;
        nodeSubRec[NSR_DIGEST_BIN]   = digestList;
        -- Call udpate to mark the SubRec as dirty, and to force the write
        -- if we are in "early update" mode. Close will happen at the end
        -- of the Lua call.
        ldt_common.updateSubRec( src, nodeSubRec );
      end
    else
      -- Bummer.  Errors.
      warn("[ERROR]<%s:%s> Parent Node Errors in NodeInsert", MOD, meth );
      error( ldte.ERR_INTERNAL );
    end
  else
    -- Complex node split and propagate up to parent.  Special case is if
    -- this is a ROOT split, which is different.
    rc = splitNodeInsert( src, topRec, sp, ldtCtrl, key, digest, level);
  end

  GP=F and trace("[EXIT]<%s:%s> rc(%s)", MOD, meth, tostring(rc) );
  return rc;
end -- insertParentNode()

-- ======================================================================
-- Create a new Leaf Page and initialize it.
-- Parms:
-- (*) src: subrecContext: The pool of open subrecords
-- (*) topRec: The main AS Record holding the LDT
-- (*) ldtCtrl: Main LDT Control Structure
-- (*) firstValue: if present, insert this value
-- NOTE: Remember that we must create an ESR when we create the first leaf
-- but that is the caller's job
-- Contents of a Leaf Record:
-- (1) SUBREC_PROP_BIN: Main record Properties go here
-- (2) LSR_CTRL_BIN:    Main Leaf Control structure
-- (3) LSR_LIST_BIN:    Object List goes here
-- (4) LSR_BINARY_BIN:  Packed Binary Array (if used) goes here
-- ======================================================================
-- ======================================================================
-- initializeLeaf()
-- Set the values in an Inner Tree Node Control Map and Key/Digest Lists.
-- There are potentially FOUR bins in an Interior Tree Node Record:
-- (0) nodeSubRec[SUBREC_PROP_BIN]: The Property Map
-- (1) nodeSubRec[LSR_CTRL_BIN]:   The control Map (defined here)
-- (2) nodeSubRec[LSR_LIST_BIN]:   The Data Entry List (when in list mode)
-- (3) nodeSubRec[LSR_BINARY_BIN]: The Packed Data Bytes (when in Binary mode)
-- Pages are either in "List" mode or "Binary" mode (the whole tree is in
-- one mode or the other), so the record will employ only four fields.
-- Either Bins 0,1,2,4 or Bins 0,1,3,5.
-- Parms:
-- (*) topRec
-- (*) ldtCtrl
-- (*) leafSubRec
-- (*) firstValue: If present, store this first value in the leaf.
-- (*) valueList: If present, store this value LIST in the leaf.  Note that
--     "firstValue" and "valueList" are mutually exclusive.  If BOTH are
--     non-NIL, then the valueList wins (firstValue not inserted).
-- (*) pd: previous (left) Leaf Digest (or 0, if not there)
-- (*) nd: next (right) Leaf Digest (or 0, if not there)
-- ======================================================================
local function createLeafRec( src, topRec, ldtCtrl, firstValue, valueList )
  local meth = "createLeafRec()";
  GP=E and trace("[ENTER]<%s:%s> ldtSum(%s) firstVal(%s)", MOD, meth,
    ldtSummaryString(ldtCtrl), tostring(firstValue));

  -- Extract the property map and control map from the ldt bin list.
  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];

  -- Create the Aerospike Sub-Record, initialize the Bins (Ctrl, List).
  -- The createSubRec() handles the record type and the SRC.
  -- It also kicks out with an error if something goes wrong.
  local leafSubRec = ldt_common.createSubRec( src, topRec, ldtCtrl, RT_SUB );
  local leafPropMap = leafSubRec[SUBREC_PROP_BIN];
  local leafCtrlMap = map();

  -- Store the new maps in the record.
  -- leafSubRec[SUBREC_PROP_BIN] = leafPropMap; (Already Set)
  leafSubRec[LSR_CTRL_BIN]    = leafCtrlMap;
  local leafItemCount = 0;

  local topDigest = record.digest( topRec );
  local leafDigest = record.digest( leafSubRec );
  
  GP=F and trace("[DEBUG]<%s:%s> Checking Store Mode(%s) (List or Binary?)",
    MOD, meth, tostring( ldtMap[M_StoreMode] ));

  if( ldtMap[M_StoreMode] == SM_LIST ) then
    -- <><> List Mode <><>
    GP=F and trace("[DEBUG]: <%s:%s> Initialize in LIST mode", MOD, meth );
    leafCtrlMap[LF_ByteEntryCount] = 0;
    -- If we have an initial value, then enter that in our new object list.
    -- Otherwise, create an empty list.
    local objectList;
    local leafItemCount = 0;

    -- If we have a value (or list) passed in, process it.
    if ( valueList ~= nil ) then
      objectList = valueList;
      leafItemCount = list.size(valueList);
    else
      objectList = list();
      if ( firstValue ~= nil ) then
        list.append( objectList, firstValue );
        leafItemCount = 1;
      end
    end

    -- Store stats and values in the new Sub-Record
    leafSubRec[LSR_LIST_BIN] = objectList;
    leafCtrlMap[LF_ListEntryCount] = leafItemCount;
    leafCtrlMap[LF_ListEntryTotal] = leafItemCount;

  else
    -- <><> Binary Mode <><>
    GP=F and trace("[DEBUG]: <%s:%s> Initialize in BINARY mode", MOD, meth );
    warn("[WARNING!!!]<%s:%s>BINARY MODE Still Under Construction!",MOD,meth );
    leafCtrlMap[LF_ListEntryTotal] = 0;
    leafCtrlMap[LF_ListEntryCount] = 0;
    leafCtrlMap[LF_ByteEntryCount] = startCount;
  end

  -- Take our new structures and put them in the leaf record.
  -- leafSubRec[SUBREC_PROP_BIN] = leafPropMap; (Already Set)
  leafSubRec[LSR_CTRL_BIN] = leafCtrlMap;

  ldt_common.updateSubRec( src, leafSubRec );
  
  -- Note that the caller will write out the record, since there will
  -- possibly be more to do (like add data values to the object list).
  GP=F and trace("[DEBUG]<%s:%s> TopRec Digest(%s) Leaf Digest(%s))",
    MOD, meth, tostring(topDigest), tostring(leafDigest));

  GP=F and trace("[DEBUG]<%s:%s> LeafPropMap(%s) Leaf Map(%s)",
    MOD, meth, tostring(leafPropMap), tostring(leafCtrlMap));

  -- Must wait until subRec is initialized before it can be added to SRC.
  -- It should be ready now.
  -- ldt_common.addSubRecToContext( src, leafSubRec, true );

  GP=F and trace("[EXIT]<%s:%s> rc(%s)", MOD, meth, tostring(rc) );
  return leafSubRec;
end -- createLeafRec()

-- ======================================================================
-- splitLeafInsert()
-- We already know that there isn't enough room for the item, so we'll
-- have to split the leaf in order to insert it.
-- The searchPath position tells us the insert location in THIS leaf,
-- but, since this leaf will have to be split, it gets more complicated.
-- We split, THEN decide which leaf to use.
-- ALSO -- since we don't want to split the page in the middle of a set of
-- duplicates, we have to find the closest "key break" to the middle of
-- the page.  More thinking needed on how to handle duplicates without
-- making the page MUCH more complicated.
-- For now, we'll make the split easier and just pick the middle item,
-- but in doing that, it will make the scanning more complicated.
-- Parms:
-- (*) src: subrecContext
-- (*) topRec
-- (*) sp: searchPath
-- (*) ldtCtrl
-- (*) newKey
-- (*) newValue
-- Return:
-- ======================================================================
local function
splitLeafInsert( src, topRec, sp, ldtCtrl, newKey, newValue )
  local meth = "splitLeafInsert()";
  local rc = 0;

  GP=B and trace("\n\n <><><> !!! SPLIT LEAF !!! <><><> \n\n");

  GP=E and trace("[ENTER]<%s:%s> SP(%s) Key(%s) Val(%s) LDT Map(%s) ",
    MOD, meth, tostring(sp), tostring(newKey), tostring(newValue),
    ldtSummaryString(ldtCtrl));

  -- Splitting a leaf works as follows.  It is slightly different than a
  -- node split.  The leaf is split into a left piece and a right piece. 
  --
  -- The first element if the right leaf becomes the new key that gets
  -- propagated up to the parent.  This is the main difference between a Leaf
  -- split and a node split.  The leaf split uses a COPY of the key, whereas
  -- the node split removes that key from the node and moves it to the parent.
  --
  --  Inner Node   +---+---+
  --  Key List     |111|888|
  --               +---+---+
  --  Digest List  A   B   C
  --
  -- +---+---+    +---+---+---+---+---+    +---+---+
  -- | 50| 88|    |111|222|333|444|555|    |888|999|
  -- +---+---+    +---+---+---+---+---+    +---+---+
  -- Leaf A       Leaf B                   Leaf C
  --
  --                      +---+
  -- Copy of key element  |333|
  -- moves up to parent   +---+
  -- node.                ^ ^ ^ 
  --              +---+---+   +---+---+---+
  --              |111|222|   |333|444|555|
  --              +---+---+   +---+---+---+
  --              Leaf B1     Leaf B2
  --
  --  Inner Node   +---+---+---+
  --  Key List     |111|333|888|
  --               +---+---+---+
  --  Digest List  A   B1  B2  C
  --
  -- +---+---+    +---+---+   +---+---+---+    +---+---+
  -- | 50| 88|    |111|222|   |333|444|555|    |888|999|
  -- +---+---+    +---+---+   +---+---+---+    +---+---+
  -- Leaf A       Leaf B1     Leaf B2          Leaf C
  --
  -- Extract the property map and control map from the ldt bin list.
  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];
  local ldtBinName = propMap[PM_BinName];

  local leafLevel = sp.LevelCount;
  local leafPosition = sp.PositionList[leafLevel];
  local leafSubRecDigest = sp.DigestList[leafLevel];
  local leafSubRec = sp.RecList[leafLevel];

  -- Open the Leaf and look inside.
  local leafMap    = leafSubRec[LSR_CTRL_BIN];
  local objectList = leafSubRec[LSR_LIST_BIN];

  -- Calculate the split position and the key to propagate up to parent.
  local splitPosition =
      getLeafSplitPosition( ldtMap, objectList, leafPosition, newValue );
  local splitKey = getKeyValue( ldtMap, objectList[splitPosition] );

  GP=F and trace("[STATUS]<%s:%s> Got Split Key(%s) at position(%d)",
    MOD, meth, tostring(splitKey), splitPosition );

  GP=F and trace("[STATUS]<%s:%s> About to Take and Drop:: List(%s)",
    MOD, meth, tostring(objectList));

  -- Our List operators :
  -- (*) list.take (take the first N elements) 
  -- (*) list.drop (drop the first N elements, and keep the rest) 
  -- will let us split the current leaf list into two leaf lists.
  -- We will always propagate up the new Key and the NEW left page (digest)
  local leftList  = list.take( objectList, splitPosition - 1 );
  local rightList = list.drop( objectList, splitPosition - 1 );

  GP=F and trace("\n[DEBUG]<%s:%s>: LeftList(%s) SplitKey(%s) RightList(%s)",
    MOD, meth, tostring(leftList), tostring(splitKey), tostring(rightList) );

  local rightLeafRec = leafSubRec; -- our new name for the existing leaf
  local leftLeafRec = createLeafRec( src, topRec, ldtCtrl, nil );
  local leftLeafDigest = record.digest( leftLeafRec );

  -- Overwrite the leaves with their new object value lists
  populateLeaf( src, leftLeafRec, leftList );
  populateLeaf( src, rightLeafRec, rightList );

  -- Update the Page Pointers: Given that they are doubly linked, we can
  -- easily find the ADDITIONAL page that we have to open so that we can
  -- update its next-page link.  If we had to go up and down the tree to find
  -- it (the near LEFT page) that would be a horrible HORRIBLE experience.
  rc = adjustPagePointers( src, topRec, ldtMap, leftLeafRec, rightLeafRec );

  -- Now figure out WHICH of the two leaves (original or new) we have to
  -- insert the new value.
  -- Compare against the SplitKey -- if less, insert into the left leaf,
  -- and otherwise insert into the right leaf.
  local compareResult = keyCompare( newKey, splitKey );
  if( compareResult == CR_LESS_THAN ) then
    -- We choose the LEFT Leaf -- but we must search for the location
    leafInsert(src, topRec, leftLeafRec, ldtMap, newKey, newValue, 0);
  elseif( compareResult >= CR_EQUAL  ) then -- this works for EQ or GT
    -- We choose the RIGHT (new) Leaf -- but we must search for the location
    leafInsert(src, topRec, rightLeafRec, ldtMap, newKey, newValue, 0);
  else
    -- We got some sort of goofy error.
    warn("[ERROR]<%s:%s> Compare Error(%d)", MOD, meth, compareResult );
    error( ldte.ERR_INTERNAL );
  end

  -- Call udpate to mark the SubRec as dirty, and to force the write if we
  -- are in "early update" mode. Close will happen at the end of the Lua call.
  ldt_common.updateSubRec( src, leftLeafRec );
  ldt_common.updateSubRec( src, rightLeafRec );

  -- Update the parent node with the new leaf information.  It is the job
  -- of this method to either split the parent or do a straight insert.
  GP=F and trace("\n\n CALLING INSERT PARENT FROM SPLIT LEAF: Key(%s)\n",
    tostring(splitKey));
  insertParentNode(src, topRec, sp, ldtCtrl, splitKey,
    leftLeafDigest, leafLevel - 1 );

  GP=F and trace("[EXIT]<%s:%s> rc(%s)", MOD, meth, tostring(rc) );
  return rc;
end -- splitLeafInsert()

-- ======================================================================
-- buildNewTree( src, topRec, ldtMap, leftLeafList, splitKey, rightLeafList );
-- ======================================================================
-- Build a brand new tree -- from the contents of the Compact List.
-- This is the efficient way to construct a new tree.
-- Note that this function is assumed to take data from the Compact List.
-- It is not meant for LARGE lists, where the supplied LEFT and RIGHT lists
-- could each overflow a single leaf.
--
-- Parms:
-- (*) src: SubRecContext
-- (*) topRec
-- (*) ldtCtrl
-- (*) leftLeafList
-- (*) keyValue
-- (*) rightLeafList )
-- ======================================================================
local function buildNewTree( src, topRec, ldtCtrl,
                             leftLeafList, keyValue, rightLeafList )
  local meth = "buildNewTree()";
  local rc = 0;
  GP=E and trace("[ENTER]<%s:%s> LeftList(%s) Key(%s) RightList(%s)",MOD,meth,
    tostring(leftLeafList), tostring(keyValue), tostring(rightLeafList));

  GD=DEBUG and trace("[DEBUG]<%s:%s> LdtSummary(%s)",
    MOD, meth, ldtSummaryString( ldtCtrl ));

  -- Just need the Control Map
  local ldtMap  = ldtCtrl[2];

  -- These are set on create -- so we can use them, even though they are
  -- (or should be) empty.
  local rootKeyList = ldtMap[R_RootKeyList];
  local rootDigestList = ldtMap[R_RootDigestList];

  -- Create two leaves -- Left and Right. Initialize them.  Then
  -- assign our new value lists to them.
  local leftLeafRec = createLeafRec( src, topRec, ldtCtrl, nil, leftLeafList);
  local leftLeafDigest = record.digest( leftLeafRec );
  ldtMap[R_LeftLeafDigest] = leftLeafDigest; -- Remember Left-Most Leaf

  local rightLeafRec = createLeafRec( src, topRec, ldtCtrl, nil, rightLeafList);
  local rightLeafDigest = record.digest( rightLeafRec );
  ldtMap[R_RightLeafDigest] = rightLeafDigest; -- Remember Right-Most Leaf

  -- Our leaf pages are doubly linked -- we use digest values as page ptrs.
  setLeafPagePointers( src, leftLeafRec, 0, rightLeafDigest );
  setLeafPagePointers( src, rightLeafRec, leftLeafDigest, 0 );

  GP=F and trace("[DEBUG]<%s:%s>Created Left(%s) and Right(%s) Records",
    MOD, meth, tostring(leftLeafDigest), tostring(rightLeafDigest) );

  -- Build the Root Lists (key and digests)
  list.append( rootKeyList, keyValue );
  list.append( rootDigestList, leftLeafDigest );
  list.append( rootDigestList, rightLeafDigest );

  ldtMap[R_TreeLevel] = 2; -- We can do this blind, since it's special.

  -- Note: The caller will update the top record, but we need to update the
  -- subrecs here.
  -- Call udpate to mark the SubRec as dirty, and to force the write if we
  -- are in "early update" mode. Close will happen at the end of the Lua call.
  ldt_common.updateSubRec( src, leftLeafRec );
  ldt_common.updateSubRec( src, rightLeafRec );

  GP=F and trace("[EXIT]<%s:%s>ldtMap(%s) newValue(%s) rc(%s)",
    MOD, meth, tostring(ldtMap), tostring(newValue), tostring(rc));
  return rc;
end -- buildNewTree()

-- ======================================================================
-- firstTreeInsert( topRec, ldtCtrl, newValue, stats )
-- ======================================================================
-- For the VERY FIRST INSERT, we don't need to search.  We just put the
-- first key in the root, and we allocate TWO leaves: the left leaf for
-- values LESS THAN the first value, and the right leaf for values
-- GREATER THAN OR EQUAL to the first value.
--
-- Notice that this is a medium-level MISTAKE if, in fact, we're about
-- to build a tree from a sorted list -- but that's another story.
-- Parms:
-- (*) src: SubRecContext
-- (*) topRec
-- (*) ldtCtrl
-- (*) newValue
-- (*) stats: bool: When true, we update stats
local function firstTreeInsert( src, topRec, ldtCtrl, newValue, stats )
  local meth = "firstTreeInsert()";
  local rc = 0;
  GP=E and trace("[ENTER]<%s:%s> newValue(%s) LdtSummary(%s)",
    MOD, meth, tostring(newValue), ldtSummaryString(ldtCtrl) );

  -- We know that on the VERY FIRST SubRecord create, we want to create
  -- the Existence Sub Record (ESR).  So, do this first.
  --NOT NEEDED -- ESR will be created by createLeafRec()
  --local esrDigest = createAndInitESR( src, topRec, ldtCtrl );

  -- Extract the property map and control map from the ldt bin list.
  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];
  local ldtBinName = propMap[PM_BinName];

  local rootKeyList = ldtMap[R_RootKeyList];
  local rootDigestList = ldtMap[R_RootDigestList];
  local keyValue = getKeyValue( ldtMap, newValue );

  -- Create two leaves -- Left and Right. Initialize them.  Then
  -- insert our new value into the RIGHT one.
  local leftLeafRec = createLeafRec( src, topRec, ldtCtrl, nil, nil );
  local leftLeafDigest = record.digest( leftLeafRec );
  ldtMap[R_LeftLeafDigest] = leftLeafDigest; -- Remember Left-Most Leaf

  local rightLeafRec = createLeafRec( src, topRec, ldtCtrl, newValue, nil );
  local rightLeafDigest = record.digest( rightLeafRec );
  ldtMap[R_RightLeafDigest] = rightLeafDigest; -- Remember Right-Most Leaf

  -- Our leaf pages are doubly linked -- we use digest values as page ptrs.
  setLeafPagePointers( src, leftLeafRec, 0, rightLeafDigest );
  setLeafPagePointers( src, rightLeafRec, leftLeafDigest, 0 );

  GP=F and trace("[DEBUG]<%s:%s>Created Left(%s) and Right(%s) Records",
    MOD, meth, tostring(leftLeafDigest), tostring(rightLeafDigest) );

  -- Insert our very first key into the root directory (no search needed),
  -- along with the two new child digests
  list.append( rootKeyList, keyValue );
  list.append( rootDigestList, leftLeafDigest );
  list.append( rootDigestList, rightLeafDigest );

  if( stats == true ) then
    local totalCount = ldtMap[R_TotalCount];
    ldtMap[R_TotalCount] = totalCount + 1;
    local itemCount = propMap[PM_ItemCount];
    propMap[PM_ItemCount] = itemCount + 1;
  end

  ldtMap[R_TreeLevel] = 2; -- We can do this blind, since it's special.

  -- Still experimenting -- not sure how much we have to "reset", but some
  -- things are not currently being updated correctly.
  -- TODO: @TOBY: Double check this and fix.
  ldtMap[R_RootKeyList] = rootKeyList;
  ldtMap[R_RootDigestList] = rootDigestList;
  -- ldtCtrl[2] = ldtMap;
  topRec[ldtBinName] = ldtCtrl;
  record.set_flags(topRec, ldtBinName, BF_LDT_BIN );--Must set every time

  -- Note: The caller will update the top record, but we need to update the
  -- subrecs here.
  -- Call udpate to mark the SubRec as dirty, and to force the write if we
  -- are in "early update" mode. Close will happen at the end of the Lua call.
  ldt_common.updateSubRec( src, leftLeafRec );
  ldt_common.updateSubRec( src, rightLeafRec );

  GP=F and trace("[EXIT]<%s:%s>LdtSummary(%s) newValue(%s) rc(%s)",
    MOD, meth, ldtSummaryString(ldtCtrl), tostring(newValue), tostring(rc));
  return rc;
end -- firstTreeInsert()

-- ======================================================================
-- treeInsert( src, topRec, ldtCtrl, value, stats )
-- ======================================================================
-- Search the tree (start with the root and move down).  Get the spot in
-- the leaf where the insert goes.  Insert into the leaf.  Remember the
-- path on the way down, because if a leaf splits, we have to move back
-- up and potentially split the parents bottom up.
-- Parms:
-- (*) src: subrecContext: The pool of open subrecords
-- (*) topRec
-- (*) ldtCtrl
-- (*) value
-- (*) stats: bool: When true, we update stats
-- ======================================================================
local function treeInsert( src, topRec, ldtCtrl, value, stats )
  local meth = "treeInsert()";
  local rc = 0;
  
  GP=E and trace("[ENTER]<%s:%s>", MOD, meth );

  GP=F and trace("[PARMS]<%s:%s>value(%s) stats(%s) LdtSummary(%s) ",
  MOD, meth, tostring(value), tostring(stats), ldtSummaryString(ldtCtrl));

  -- Extract the property map and control map from the ldt bin list.
  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];
  local ldtBinName = propMap[PM_BinName];

  local key = getKeyValue( ldtMap, value );

  -- For the VERY FIRST INSERT, we don't need to search.  We just put the
  -- first key in the root, and we allocate TWO leaves: the left leaf for
  -- values LESS THAN the first value, and the right leaf for values
  -- GREATER THAN OR EQUAL to the first value.
  -- Note that later -- when we do a batch insert -- this will be smarter.
  if( ldtMap[R_TreeLevel] == 1 ) then
    GP=F and trace("[DEBUG]<%s:%s>\n\n<FFFF> FIRST TREE INSERT!!!\n",
        MOD, meth );
    firstTreeInsert( src, topRec, ldtCtrl, value, stats );
  else
    GP=F and trace("[DEBUG]<%s:%s>\n\n<RRRR> Regular TREE INSERT(%s)!!!\n\n",
        MOD, meth, tostring(value));
    -- It's a real insert -- so, Search first, then insert
    -- Map: Path from root to leaf, with indexes
    -- The Search path is a map of values, including lists from root to leaf
    -- showing node/list states, counts, fill factors, etc.
    local sp = createSearchPath(ldtMap);
    local status =
      treeSearch( src, topRec, sp, ldtCtrl, key );

    if( status == ST_FOUND and ldtMap[R_KeyUnique] == AS_TRUE ) then
      warn("[User ERROR]<%s:%s> Unique Key(%s) Violation",
        MOD, meth, tostring(value ));
      error( ldte.ERR_UNIQUE_KEY );
    end
    local leafLevel = sp.LevelCount;

    GP=F and trace("[DEBUG]<%s:%s>LeafInsert: Level(%d): HasRoom(%s)",
      MOD, meth, leafLevel, tostring(sp.HasRoom[leafLevel] ));

    if( sp.HasRoom[leafLevel] == true ) then
      -- Regular Leaf Insert
      local leafSubRec = sp.RecList[leafLevel];
      local position = sp.PositionList[leafLevel];
      rc = leafInsert(src, topRec, leafSubRec, ldtMap, key, value, position);
      -- Call update_subrec() to both mark the subRec as dirty, AND to write
      -- it out if we are in "early update" mode.  In general, Dirty SubRecs
      -- are also written out and closed at the end of the Lua Context.
      ldt_common.updateSubRec( src, leafSubRec );
    else
      -- Split first, then insert.  This split can potentially propagate all
      -- the way up the tree to the root. This is potentially a big deal.
      rc = splitLeafInsert( src, topRec, sp, ldtCtrl, key, value );
    end
  end -- end else "real" insert

  -- All of the subrecords were written out in the respective insert methods,
  -- so if all went well, we'll now update the top record. Otherwise, we
  -- will NOT udate it.
  if( rc == nil or rc == 0 ) then
    GP=F and trace("[DEBUG]<%s:%s>::Updating TopRec: rc(%s)",
      MOD, meth, tostring( rc ));
    rc = aerospike:update( topRec );
    if ( rc ~= 0 ) then
      warn("[ERROR]<%s:%s>TopRec Update Error rc(%s)",MOD,meth,tostring(rc));
      error( ldte.ERR_TOPREC_UPDATE );
    end 
  else
    warn("[ERROR]<%s:%s>Insert Error::Ldt(%s) value(%s) stats(%s) rc(%s)",
      MOD, meth, ldtSummaryString(ldtCtrl), tostring(value), tostring(stats),
      tostring(rc));
    error( ldte.ERR_INSERT );
  end

  GP=F and trace("[EXIT]<%s:%s>LdtSummary(%s) value(%s) rc(%s)",
    MOD, meth, ldtSummaryString(ldtCtrl), tostring(value), tostring(rc));
  return rc;
end -- treeInsert

-- ======================================================================
-- localInsert( src, topRec, ldtCtrl, newValue, stats )
-- ======================================================================
-- Perform the main work of insert (used by both convertList() and the
-- regular insert().
-- Parms:
-- (*) src: subrecContext: The pool of open subrecords
-- (*) topRec: The top DB Record:
-- (*) ldtCtrl: The LDT control Structure
-- (*) newValue: Value to be inserted
-- (*) stats: true=Please update Counts, false=Do NOT update counts (rehash)
-- ======================================================================
local function localInsert(src, topRec, ldtCtrl, newValue, stats )
  local meth = "localInsert()";
  GP=E and trace("[ENTER]:<%s:%s>Insert(%s)", MOD, meth, tostring(newValue));
  local rc = 0;
  
  -- Extract the property map and control map from the ldt bin list.
  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];
  local ldtBinName = propMap[PM_BinName];

  -- If our state is "compact", do a simple list insert, otherwise do a
  -- real tree insert.
  local insertResult = 0;
  if( ldtMap[R_StoreState] == SS_COMPACT ) then 
    -- Do the COMPACT LIST INSERT
    GP=F and trace("[NOTICE]<%s:%s> Using >>>  LIST INSERT  <<<", MOD, meth);
    local objectList = ldtMap[R_CompactList];
    local key = getKeyValue( ldtMap, newValue );
    local resultMap = searchObjectList( ldtMap, objectList, key );
    if( resultMap.Status == ERR_OK ) then
      -- If FOUND, then we have to verify that Duplicates are allowed.
      -- Otherwise, do the insert.
      if( resultMap.Found == true and ldtMap[R_KeyUnique] == AS_TRUE ) then
        warn("[ERROR]<%s:%s> Unique Key Violation", MOD, meth );
        error( ldte.ERR_UNIQUE_KEY );
      end
      local position = resultMap.Position;
      rc = listInsert( objectList, newValue, position );
      GP=F and trace("[DEBUG]<%s:%s> Insert List rc(%d)", MOD, meth, rc );
      if( rc < 0 ) then
        warn("[ERROR]<%s:%s> Problems with Insert: RC(%d)", MOD, meth, rc );
        error( ldte.ERR_INTERNAL );
      end
    else
      warn("[Internal ERROR]<%s:%s> Key(%s), List(%s)", MOD, meth,
        tostring( key ), tostring( objectList ) );
      error( ldte.ERR_INTERNAL );
    end
  else
    -- Do the TREE INSERT
    GP=F and trace("[NOTICE]<%s:%s> Using >>>  TREE INSERT  <<<", MOD, meth);
    insertResult = treeInsert(src, topRec, ldtCtrl, newValue, stats );
  end

  -- update stats if appropriate.
  if( stats == true and insertResult >= 0 ) then -- Update Stats if success
    local itemCount = propMap[PM_ItemCount];
    local totalCount = ldtMap[R_TotalCount];
    propMap[PM_ItemCount] = itemCount + 1; -- number of valid items goes up
    ldtMap[R_TotalCount] = totalCount + 1; -- Total number of items goes up
    GP=F and trace("[DEBUG]: <%s:%s> itemCount(%d)", MOD, meth, itemCount );
  end
  topRec[ ldtBinName ] = ldtCtrl;
  record.set_flags(topRec, ldtBinName, BF_LDT_BIN );--Must set every time

  GP=F and trace("[EXIT]: <%s:%s>Storing Record() with New Value(%s): Map(%s)",
                 MOD, meth, tostring( newValue ), tostring( ldtMap ) );
    -- No need to return anything
end -- localInsert

-- ======================================================================
-- getNextLeaf( src, topRec, leafSubRec  )
-- Our Tree Leaves are doubly linked -- so from any leaf we can move 
-- right or left.  Get the next leaf (right neighbor) in the chain.
-- This is called primarily by scan(), so the pages should be clean.
-- ======================================================================
local function getNextLeaf( src, topRec, leafSubRec  )
  local meth = "getNextLeaf()";
  GP=E and trace("[ENTER]<%s:%s> TopRec(%s) src(%s) LeafSummary(%s)",
    MOD, meth, tostring(topRec), tostring(src), leafSummaryString(leafSubRec));

  local leafSubRecMap = leafSubRec[LSR_CTRL_BIN];
  local nextLeafDigest = leafSubRecMap[LF_NextPage];

  local nextLeaf = nil;
  local nextLeafDigestString;

  -- Close the current leaf before opening the next one.  It should be clean,
  -- so closing is ok.
  -- aerospike:close_subrec( leafSubRec );
  ldt_common.closeSubRec( src, leafSubRec, false);

  if( nextLeafDigest ~= nil and nextLeafDigest ~= 0 ) then
    nextLeafDigestString = tostring( nextLeafDigest );
    GP=F and trace("[OPEN SUB REC]:<%s:%s> Digest(%s)",
      MOD, meth, nextLeafDigestString);

    nextLeaf = ldt_common.openSubRec( src, topRec, nextLeafDigestString )
    if( nextLeaf == nil ) then
      warn("[ERROR]<%s:%s> Can't Open Leaf(%s)",MOD,meth,nextLeafDigestString);
      error( ldte.ERR_SUBREC_OPEN );
    end
  end

  GP=F and trace("[EXIT]<%s:%s> Returning NextLeaf(%s)",
     MOD, meth, leafSummaryString( nextLeaf ) );
  return nextLeaf;

end -- getNextLeaf()

-- ======================================================================
-- newConvertList( src, topRec, ldtBinName, ldtCtrl )
-- ======================================================================
-- When we start in "compact" StoreState (SS_COMPACT), we eventually have
-- to switch to "regular" state when we get enough values.  So, at some
-- point (StoreThreshold), we take our simple list and then insert into
-- the B+ Tree.
-- NewConvertList does the SMART thing and builds the tree from the 
-- compact list without doing any tree inserts.
-- Parms:
-- (*) src: subrecContext
-- (*) topRec
-- (*) ldtBinName
-- (*) ldtCtrl
-- ======================================================================
local function newConvertList(src, topRec, ldtBinName, ldtCtrl )
  local meth = "newConvertList()";

  GP=E and trace("[ENTER]<%s:%s>\n\n<><> NEW CONVERT LIST <><>\n\n",MOD,meth);

  GP=F and trace("[DEBUG]<%s:%s> BinName(%s) LDT Summary(%s)", MOD, meth,
    tostring(ldtBinName), ldtSummaryString(ldtCtrl));
  
  -- Extract the property map and control map from the ldt bin list.
  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];
  local ldtBinName = propMap[PM_BinName];

  -- Get the compact List, cut it in half, build the two leaves, and
  -- copy the min value of the right leaf into the root.
  local compactList = ldtMap[R_CompactList];

  if compactList == nil then
    warn("[INTERNAL ERROR]:<%s:%s> Rehash can't use Empty Bin (%s) list",
      MOD, meth, tostring(singleBinName));
    error( ldte.ERR_INTERNAL );
  end

  ldtMap[R_StoreState] = SS_REGULAR; -- now in "regular" (modulo) mode

  -- Notice that the actual "split position" is AFTER the splitPosition
  -- value -- so if we were splitting 10, the list would split AFTER 5,
  -- and index 6 would be the first entry of the right list and thus the
  -- location of the split key.
  local splitPosition = list.size(compactList) / 2;
  local splitValue = compactList[splitPosition + 1];
  local splitKey = getKeyValue( ldtMap, splitValue );

  -- Our List operators :
  -- (*) list.take (take the first N elements)
  -- (*) list.drop (drop the first N elements, and keep the rest)
  local leftLeafList  =  list.take( compactList, splitPosition );
  local rightLeafList =  list.drop( compactList, splitPosition );

  -- Toss the old Compact List;  No longer needed.  However, we must replace
  -- it with an EMPTY list, not a NIL.
  ldtMap[R_CompactList] = list();

  -- Now build the tree:
  buildNewTree( src, topRec, ldtCtrl, leftLeafList, splitKey, rightLeafList );

  GP=F and trace("[EXIT]: <%s:%s> ldtSummary(%s)",
    MOD, meth, ldtSummaryString(ldtCtrl));
  return 0;
end -- newConvertList()


-- ======================================================================
-- convertList( topRec, ldtBinName, ldtCtrl )
-- ======================================================================
-- When we start in "compact" StoreState (SS_COMPACT), we eventually have
-- to switch to "regular" state when we get enough values.  So, at some
-- point (StoreThreshold), we take our simple list and then insert into
-- the B+ Tree.
-- So -- copy out all of the items from the CompactList and
-- then resinsert them using "regular" mode.
-- Parms:
-- (*) src: subrecContext
-- (*) topRec
-- (*) ldtBinName
-- (*) ldtCtrl
-- ======================================================================
local function convertList(src, topRec, ldtBinName, ldtCtrl )
  local meth = "convertList()";

  GP=E and trace("[ENTER]<%s:%s>\n\n <><>  CONVERT LIST <><>\n\n", MOD, meth );
  
  -- Extract the property map and control map from the ldt bin list.
  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];
  local ldtBinName = propMap[PM_BinName];

  -- iterate thru the ldtMap CompactList, re-inserting each item.
  local compactList = ldtMap[R_CompactList];

  if compactList == nil then
    warn("[INTERNAL ERROR]:<%s:%s> Rehash can't use Empty Bin (%s) list",
      MOD, meth, tostring(singleBinName));
    error( ldte.ERR_INTERNAL );
  end

  ldtMap[R_StoreState] = SS_REGULAR; -- now in "regular" (modulo) mode

  -- Rebuild. Take the compact list and insert it into the tree.
  -- The good way to do it is to sort the items and put them into a leaf
  -- in sorted order.  The simple way is to insert each one into the tree.
  -- Start with the SIMPLE way.
  -- TODO: @TOBY: Change this to build the tree in one operation.
  for i = 1, list.size( compactList ), 1 do
    -- Do NOT update counts, as we're just RE-INSERTING existing values.
    treeInsert( src, topRec, ldtCtrl, compactList[i], false );
  end

  -- Now, release the compact list we were using.
  -- TODO: Figure out exactly how Lua releases storage
  -- ldtMap[R_CompactList] = nil; -- Release the list.  Does this work??
  ldtMap[R_CompactList] = list();  -- Replace with an empty list.

  GP=F and trace("[EXIT]: <%s:%s> ldtSummary(%s)",
    MOD, meth, ldtSummaryString(ldtCtrl));
  return 0;
end -- convertList()

-- ======================================================================
-- Given the searchPath result from treeSearch(), Scan the leaves for all
-- values that satisfy the searchPredicate and the filter.
-- Parms:
-- (*) src: subrecContext
-- (*) resultList: stash the results here
-- (*) topRec: Top DB Record
-- (*) sp: Search Path Object
-- (*) ldtCtrl: The Truth
-- (*) key: the end marker: 
-- (*) flag: Either Scan while equal to end, or Scan until val > end.
-- ======================================================================
local function treeScan( src, resultList, topRec, sp, ldtCtrl, key, flag )
  local meth = "treeScan()";
  local rc = 0;
  local scan_A = 0;
  local scan_B = 0;
  GP=E and trace("[ENTER]<%s:%s> searchPath(%s) key(%s)",
      MOD, meth, tostring(sp), tostring(key) );

  -- Extract the property map and control map from the ldt bin list.
  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];

  local leafLevel = sp.LevelCount;
  local leafSubRec = sp.RecList[leafLevel];

  local count = 0;
  local done = false;
  local startPosition = sp.PositionList[leafLevel];
  while not done do
    GP=F and trace("[LOOP DEBUG]<%s:%s>Loop Top: Count(%d)", MOD, meth, count );
    -- NOTE: scanLeaf() actually returns a "double" value -- the first is
    -- the scan instruction (stop=0, continue=1) and the second is the error
    -- return code.  So, if scan_B is "ok" (0), then we look to scan_A to see
    -- if we should continue the scan.
    scan_A, scan_B  = scanLeaf(topRec, leafSubRec, startPosition, ldtMap,
                              resultList, key, flag)

-- Uncomment this line to see the "LEAF BOUNDARIES" in the data.
-- It's purely for debugging
-- list.append(resultList, 999999 );

    -- Look and see if there's more scanning needed. If so, we'll read
    -- the next leaf in the tree and scan another leaf.
    if( scan_B < 0 ) then
      warn("[ERROR]<%s:%s> Problems in ScanLeaf() A(%s) B(%s)",
        MOD, meth, tostring( scan_A ), tostring( scan_B ) );
      error( ldte.ERR_INTERNAL );
    end
      
    if( scan_A == SCAN_CONTINUE ) then
      GP=F and trace("[STILL SCANNING]<%s:%s>", MOD, meth );
      startPosition = 1; -- start of next leaf
      leafSubRec = getNextLeaf( src, topRec, leafSubRec );
      if( leafSubRec == nil ) then
        GP=F and trace("[NEXT LEAF RETURNS NIL]<%s:%s>", MOD, meth );
        done = true;
      end
    else
      GP=F and trace("[DONE SCANNING]<%s:%s>", MOD, meth );
      done = true;
    end
  end -- while not done reading the T-leaves

  GP=F and trace("[EXIT]<%s:%s>SearchKey(%s) SP(%s) ResSz(%d) ResultList(%s)",
      MOD,meth,tostring(key),tostring(sp),list.size(resultList),
      tostring(resultList));

  return rc;

end -- treeScan()

-- ======================================================================
-- listDelete()
-- ======================================================================
-- General List Delete function that can be used to delete items, employees
-- or pesky Indian Developers (usually named "Raj").
-- RETURN:
-- A NEW LIST that 
-- ======================================================================
local function listDelete( objectList, key, position )
  local meth = "listDelete()";
  local resultList;
  local listSize = list.size( objectList );

  GP=E and trace("[ENTER]<%s:%s>List(%s) size(%d) Key(%s) Position(%d)", MOD,
  meth, tostring(objectList), listSize, tostring(key), position );
  
  if( position < 1 or position > listSize ) then
    warn("[DELETE ERROR]<%s:%s> Bad position(%d) for delete: key(%s)",
      MOD, meth, position, tostring(key));
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
  -- However, because we cannot assign "nil" to a list, nor can we just
  -- trim a list, we have to build a NEW list from the old list, that
  -- contains JUST the pieces we want.
  -- So, basically, we're going to build a new list out of the LEFT and
  -- RIGHT pieces of the original list.
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

  -- When we do deletes with Dups -- we'll change this to have a 
  -- START position and an END position (or a length), rather than
  -- an assumed SINGLE cell.
  warn("[WARNING!!!]: >>>>>>>>>>>>>>>>>>>> <*>  <<<<<<<<<<<<<<<<<<<<<<");
  warn("[WARNING!!!]: Currently performing ONLY single item delete");
  warn("[WARNING!!!]: >>>>>>>>>>>>>>>>>>>> <*>  <<<<<<<<<<<<<<<<<<<<<<");

  GP=F and trace("[EXIT]<%s:%s> Result: Sz(%d) List(%s)", MOD, meth,
    list.size(resultList), tostring(resultList));
  return resultList;
end -- listDelete()

-- ======================================================================
-- leafDelete()
-- ======================================================================
-- Collapse the list to get rid of the entry in the leaf.
-- We're not in the mode of "NULLing" out the entry, so we'll pay
-- the extra cost of collapsing the list around the item.  The SearchPath
-- parm shows us where the item is.
-- Parms: 
-- (*) src: SubRec Context (in case we have to open more leaves)
-- (*) sp: Search Path structure
-- (*) topRec:
-- (*) ldtCtrl:
-- (*) key: the key -- in case we need to look for more dups
-- ======================================================================
local function leafDelete( src, sp, topRec, ldtCtrl, key )
  local meth = "leafDelete()";
  GP=E and trace("[ENTER]<%s:%s> SP(%s) Key(%s) LdtCtrl(%s)", MOD, meth,
    tostring(sp), tostring(key), ldtSummaryString( ldtCtrl ));
  local rc = 0;

  -- Our list and map has already been validated.  Just use it.
  propMap = ldtCtrl[1];
  ldtMap  = ldtCtrl[2];

  local leafLevel = sp.LevelCount;
  local leafSubRec = sp.RecList[leafLevel];
  local objectList = leafSubRec[LSR_LIST_BIN];
  local position = sp.PositionList[leafLevel];
  local endPos = sp.LeafEndPosition;
  local resultList;
  
  GP=F and trace("[DUMP]Before delete: ObjectList(%s) Key(%s) Position(%d)",
    tostring(objectList), tostring(key), position);

  -- Delete is easy if it's a single value -- more difficult if MANY items
  -- (with the same value) are deleted.
  if( ldtMap[R_KeyUnique] == AS_TRUE ) then
    resultList = ldt_common.listDelete(objectList, position )
    leafSubRec[LSR_LIST_BIN] = resultList;
  else
    resultList = ldt_common.listDeleteMultiple(objectList,position,endPos);
    leafSubRec[LSR_LIST_BIN] = resultList;
  end

  -- Mark this page as dirty and possibly write it out if needed.
  ldt_common.updateSubRec( src, leafSubRec );

  GP=F and trace("[DUMP]After delete: Key(%s) Result: Sz(%d) ObjectList(%s)",
    tostring(key), list.size(resultList), tostring(resultList));

  GP=F and trace("[EXIT]<%s:%s>LdtSummary(%s) newValue(%s) rc(%s)",
    MOD, meth, ldtSummaryString(ldtCtrl), tostring(newValue), tostring(rc));
  return rc;
end -- leafDelete()

-- ======================================================================
-- treeDelete()
-- ======================================================================
-- Perform a delete:  Remove this object from the tree. 
-- Two cases:
-- (1) Unique Key
-- (2) Duplicates Allowed.
-- Case 1: Unique Key :: For this case, just collapse the object list in the
-- leaf to remove the item.  If this empties the leaf, then we remove this
-- SubRecord and remove the entry from the parent.
-- Case 2: Duplicate Keys:
-- When we do Duplicates, then we have to address the case that the leaf
-- is completely empty, which means we also need remove the subrec from
-- the leaf chain.  HOWEVER, for now, we'll just remove the items from the
-- leaf objectList, but leave the Tree Leaves in place.  And, in either
-- case, we won't update the upper nodes.
-- We will have both a COMPACT storage mode and a TREE storage mode. 
-- When in COMPACT mode, the root node holds the list directly (linear
-- search and delete).  When in Tree mode, the root node holds the top
-- level of the tree.
-- Parms:
-- (*) src: SubRec Context
-- (*) topRec:
-- (*) ldtCtrl: The LDT Control Structure
-- (*) key:  Find and Delete the objects that match this key
-- (*) createSpec:
-- Return:
-- ERR_OK(0): if found
-- ERR_NOT_FOUND(-2): if NOT found
-- ERR_GENERAL(-1): For any other error 
-- =======================================================================
local function treeDelete( src, topRec, ldtCtrl, key )
  local meth = "treeDelete()";
  GP=E and trace("[ENTER]<%s:%s> LDT(%s) key(%s)", MOD, meth,
    ldtSummaryString( ldtCtrl ), tostring( key ));
  local rc = 0;

  -- Our list and map has already been validated.  Just use it.
  propMap = ldtCtrl[1];
  ldtMap  = ldtCtrl[2];

  local sp = createSearchPath(ldtMap);
  local status = treeSearch( src, topRec, sp, ldtCtrl, key );

  if( status == ST_FOUND ) then
    -- leafDelete() always returns zero.
    leafDelete( src, sp, topRec, ldtCtrl, key );
  else
    rc = ERR_NOT_FOUND;
  end

  -- NOTE: The caller will take care of updating the parent Record (topRec).
  GP=F and trace("[EXIT]<%s:%s>LdtSummary(%s) newValue(%s) rc(%s)",
    MOD, meth, ldtSummaryString(ldtCtrl), tostring(newValue), tostring(rc));
  return rc;
end -- treeDelete()

-- ======================================================================
-- processModule( ldtCtrl, moduleName )
-- ======================================================================
-- We expect to see several things from a user module.
-- (*) An adjust_settings() function: where a user overrides default settings
-- (*) Various filter functions (callable later during search)
-- (*) Transformation functions
-- (*) UnTransformation functions
-- The settings and transformation/untransformation are all set from the
-- adjust_settings() function, which puts these values in the control map.
-- ======================================================================
local function processModule( ldtCtrl, moduleName )
  local meth = "processModule()";
  GP=E and trace("[ENTER]<%s:%s> Process User Module(%s)", MOD, meth,
    tostring( moduleName ));

  local propMap = ldtCtrl[1];
  local ldtMap = ldtCtrl[2];

  if( moduleName ~= nil ) then
    if( type(moduleName) ~= "string" ) then
      warn("[ERROR]<%s:%s>User Module(%s) not valid::wrong type(%s)",
        MOD, meth, tostring(moduleName), type(moduleName));
      error( ldte.ERR_USER_MODULE_BAD );
    end

    local userModule = require(moduleName);
    if( userModule == nil ) then
      warn("[ERROR]<%s:%s>User Module(%s) not valid", MOD, meth, moduleName);
      error( ldte.ERR_USER_MODULE_NOT_FOUND );
    else
      local userSettings =  userModule[G_SETTINGS];
      if( userSettings ~= nil ) then
        userSettings( ldtMap ); -- hope for the best.
        ldtMap[M_UserModule] = moduleName;
      end
    end
  else
    warn("[ERROR]<%s:%s>User Module is NIL", MOD, meth );
  end

  GP=E and trace("[EXIT]<%s:%s> Module(%s) LDT CTRL(%s)", MOD, meth,
  tostring( moduleName ), ldtSummaryString(ldtCtrl));

end -- processModule()

-- ======================================================================
-- setupLdtBin()
-- Caller has already verified that there is no bin with this name,
-- so we're free to allocate and assign a newly created LDT CTRL
-- in this bin.
-- ALSO:: Caller write out the LDT bin after this function returns.
-- ======================================================================
local function setupLdtBin( topRec, ldtBinName, userModule ) 
local meth = "setupLdtBin()";
GP=E and trace("[ENTER]<%s:%s> ldtBinName(%s)",MOD,meth,tostring(ldtBinName));

  local ldtCtrl = initializeLdtCtrl( topRec, ldtBinName );
  local propMap = ldtCtrl[1]; 
  local ldtMap = ldtCtrl[2]; 
  
  -- Set the type of this record to LDT (it might already be set)
  record.set_type( topRec, RT_LDT ); -- LDT Type Rec
  
  -- If the user has passed in settings that override the defaults
  -- (the userModule), then process that now.
  if( userModule ~= nil )then
    local createSpecType = type(userModule);
    if( createSpecType == "string" ) then
      processModule( ldtCtrl, userModule );
    elseif( createSpecType == "userdata" ) then
      adjustLdtMap( ldtCtrl, userModule );
    else
      warn("[WARNING]<%s:%s> Unknown Creation Object(%s)",
        MOD, meth, tostring( userModule ));
    end
  end

  GP=F and trace("[DEBUG]: <%s:%s> : CTRL Map after Adjust(%s)",
                 MOD, meth , tostring(ldtMap));

  ldtMap[R_CompactList] = list();

  -- Sets the topRec control bin attribute to point to the 2 item list
  -- we created from InitializeLSetMap() : 
  -- Item 1 :  the property map & Item 2 : the ldtMap
  topRec[ldtBinName] = ldtCtrl; -- store in the record
  record.set_flags( topRec, ldtBinName, BF_LDT_BIN );

  -- NOTE: The Caller will write out the LDT bin.
  return 0;
end -- setupLdtBin( topRec, ldtBinName ) 

-- =======================================================================
-- treeMinGet()
-- =======================================================================
-- Get or Take the object that is associated with the MINIMUM (for now, we
-- assume this means left-most) key value.  We've been passed in a search
-- path object (sp) and we use that to look at the leaf and return the
-- first value in the list.
-- =======================================================================
local function treeMinGet( sp, ldtCtrl, take )
  local meth = "treeMinGet()";
  local rc = 0;
  local resultObject;
  GP=E and trace("[ENTER]<%s:%s> searchPath(%s) ", MOD, meth, tostring(sp));

  -- Extract the property map and control map from the ldt bin list.
  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];

  local leafLevel = sp.LevelCount;
  local leafSubRec = sp.RecList[leafLevel]; -- already open from the search.
  local objectList = leafSubRec[LSR_LIST_BIN];
  if( list.size(objectList) == 0 ) then
    warn("[ERROR]<%s:%s> Unexpected Empty List in Leaf", MOD, meth );
    error(ldte.ERR_INTERNAL);
  end

  -- We're here.  Get the minimum Object.  And, if "take" is true, then also
  -- remove it -- and we do that by generating a new list that excludes the
  -- first element.  We assume that the caller will udpate the SubRec.
  resultObject = objectList[1];
  if ( take == true ) then
    leafSubRec[LSR_LIST_BIN] = ldt_common.listDelete( objectList, 1 );
  end

  GP=E and trace("[EXIT]<%s:%s> ResultObject(%s) ",
    MOD, meth, tostring(resultObject));
  return resultObject;

end -- treeMinGet()

-- =======================================================================
-- treeMin()
-- =======================================================================
-- Drop down to the Left Leaf and then either TAKE or FIND the FIRST element.
-- Parms:
-- (*) topRec:
-- (*) ldtBinName:
-- (*) take: True if we are DELETE the MIN (first) item.
-- Result:
-- Success: Object is returned
-- Error: Error Code/String
-- =======================================================================
local function treeMin( topRec,ldtBinName, take )
  local meth = "treeMin()";
  GP=E and trace("[ENTER]<%s:%s> bin(%s) take(%s)",
    MOD, meth, tostring( ldtBinName), tostring(take));

  local rc = 0;
  -- Define our return value;
  local resultValue;
  
  -- Validate the topRec, the bin and the map.  If anything is weird, then
  -- this will kick out with a long jump error() call.
  local ldtCtrl = validateRecBinAndMap( topRec, ldtBinName, true );
  
  -- Extract the property map and control map from the ldt bin list.
  local ldtCtrl = topRec[ldtBinName];
  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];

  -- If our itemCount is ZERO, then quickly return NIL before we get into
  -- any trouble.
  if( propMap[PM_ItemCount] == 0 ) then
    info("[ATTENTION]<%s:%s> Searching for MIN of EMPTY TREE", MOD, meth );
    return nil;
  end

  -- set up the Read Functions (UnTransform, Filter)
  G_KeyFunction = ldt_common.setKeyFunction( ldtMap, true, G_KeyFunction ); 
  G_Filter, G_UnTransform =
      ldt_common.setReadFunctions( ldtMap, userModule, nil );
  G_FunctionArgs = nil;

  -- Create our subrecContext, which tracks all open SubRecords during
  -- the call.  Then, allows us to close them all at the end.
  local src = ldt_common.createSubRecContext();

  local resultA;
  local resultB;
  local storeObject;

  -- If our state is "compact", just get the first element.
  if( ldtMap[R_StoreState] == SS_COMPACT ) then 
    -- Do the COMPACT LIST SEARCH
    local objectList = ldtMap[R_CompactList];
    -- If we have a transform/untransform, do that here.
    storedObject = objectList[i];
    if( G_UnTransform ~= nil ) then
      resultObject = G_UnTransform( storedObject );
    else
      resultObject = storedObject;
    end
  else
    -- It's a "regular" Tree State, so do the Tree Operation.
    -- Note that "Left-Most" is a special case, where by using a nil key
    -- we automatically go to the "minimal" position.  We can pull
    -- the value from our Search Path (sp) Object.
    GP=F and trace("[DEBUG]<%s:%s> Searching Tree", MOD, meth );
    local sp = createSearchPath(ldtMap);
    treeSearch( src, topRec, sp, ldtCtrl, nil );
    -- We're just going to assume there's a MIN found, given that there's a
    -- non-zero tree present.  Any other error will kick out of Lua.
    resultObject = treeMinGet( sp, ldtCtrl, take );
  end -- tree extract

  GP=F and trace("[EXIT]<%s:%s>: Return(%s)", MOD, meth, tostring(resultValue));
  
  -- We have either jumped out of here via error() function call, or if
  -- we got this far, then we are supposed to have a valid resultValue.
  return resultValue;
end -- treeMin();

-- ======================================================================
-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- Large List (LLIST) Library Functions
-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- ======================================================================
-- (*) Status = llist.add(topRec, ldtBinName, newValue, userModule, src)
-- (*) Status = llist.add_all(topRec, ldtBinName, valueList, userModule, src)
-- (*) List   = llist.find(topRec,ldtBinName,key,userModule,filter,fargs, src)
-- (*) Object = llist.find_min(topRec,ldtBinName, src)
-- (*) Object = llist.find_max(topRec,ldtBinName, src)
-- (*) List   = llist.range( topRec, ldtBinName, lowKey, highKey, src) 
-- (*) List   = llist.take(topRec,ldtBinName,key,userModule,filter,fargs, src)
-- (*) Object = llist.take_min(topRec,ldtBinName, src)
-- (*) Object = llist.take_max(topRec,ldtBinName, src)
-- (*) List   = llist.scan(topRec, ldtBinName, userModule, filter, fargs, src)
-- (*) Status = llist.update(topRec, ldtBinName, userObject, src)
-- (*) Status = llist.remove(topRec, ldtBinName, searchValue  src) 
-- (*) Status = llist.destroy(topRec, ldtBinName, src)
-- (*) Number = llist.size(topRec, ldtBinName )
-- (*) Map    = llist.get_config(topRec, ldtBinName )
-- (*) Status = llist.set_capacity(topRec, ldtBinName, new_capacity)
-- (*) Status = llist.get_capacity(topRec, ldtBinName )
-- ======================================================================
-- The following functions are deprecated:
-- (*) Status =  create( topRec, ldtBinName, createSpec )
--
-- ======================================================================
-- The following functions under construction:
-- (*) Object = llist.find_min(topRec,ldtBinName, src)
-- (*) Object = llist.find_max(topRec,ldtBinName, src)
-- (*) List   = llist.take(topRec,ldtBinName,key,userModule,filter,fargs, src)
-- (*) Object = llist.take_min(topRec,ldtBinName, src)
-- (*) Object = llist.take_max(topRec,ldtBinName, src)
-- (*) Status = llist.update(topRec, ldtBinName, userObject, src)
--
-- ======================================================================
-- We define a table of functions that are visible to both INTERNAL UDF
-- calls and to the EXTERNAL LDT functions.  We define this table, "lmap",
-- which contains the functions that will be visible to the module.
local llist = {};

-- ======================================================================

-- ======================================================================
-- llist.create() (Deprecated)
-- ======================================================================
-- Create/Initialize a Large Ordered List  structure in a bin, using a
-- single LLIST -- bin, using User's name, but Aerospike TYPE (AS_LLIST)
--
-- We will use a LLIST control object, which contains control information and
-- two lists (the root note Key and pointer lists).
-- (*) Namespace Name
-- (*) Set Name
-- (*) Tree Node Size
-- (*) Inner Node Count
-- (*) Data Leaf Node Count
-- (*) Total Item Count
-- (*) Storage Mode (Binary or List Mode): 0 for Binary, 1 for List
-- (*) Key Storage
-- (*) Value Storage
--
-- Parms:
-- (1) topRec: the user-level record holding the LDT Bin
-- (2) LdtBinName: The user's chosen name for the LDT bin
-- (3) createSpec: The map that holds a package for adjusting LLIST settings.
function llist.create( topRec, ldtBinName, createSpec )
  GP=B and trace("\n\n >>>>>>>>> API[ LLIST CREATE ] <<<<<<<<<< \n");
  local meth = "listCreate()";
  local rc = 0;

  if createSpec == nil then
    GP=E and trace("[ENTER1]: <%s:%s> ldtBinName(%s) NULL createSpec",
      MOD, meth, tostring(ldtBinName));
  else
    GP=E and trace("[ENTER2]: <%s:%s> ldtBinName(%s) createSpec(%s) ",
    MOD, meth, tostring( ldtBinName), tostring( createSpec ));
  end

  -- Validate the BinName -- this will kick out if there's anything wrong
  -- with the bin name.
  validateBinName( ldtBinName );

  -- Check to see if LDT Structure (or anything) is already there,
  -- and if so, error
  if topRec[ldtBinName] ~= nil  then
    warn("[ERROR EXIT]: <%s:%s> LDT BIN(%s) Already Exists",
      MOD, meth, tostring(ldtBinName) );
    error( ldte.ERR_BIN_ALREADY_EXISTS );
  end

  -- Set up a new LDT Bin
  local ldtCtrl = setupLdtBin( topRec, ldtBinName, createSpec );

  GD=DEBUG and ldtDebugDump( ldtCtrl );

  -- All done, store the record
  -- With recent changes, we know that the record is now already created
  -- so all we need to do is perform the update (no create needed).
  GP=F and trace("[DEBUG]:<%s:%s>:Update Record()", MOD, meth );
  rc = aerospike:update( topRec );
  if ( rc ~= 0 ) then
    warn("[ERROR]<%s:%s>TopRec Update Error rc(%s)",MOD,meth,tostring(rc));
    error( ldte.ERR_TOPREC_UPDATE );
  end 

  GP=F and trace("[EXIT]: <%s:%s> : Done.  RC(%d)", MOD, meth, rc );
  return rc;
end -- function llist.create()

-- ======================================================================
-- llist.add() -- Insert an element into the list.
-- ======================================================================
-- This function does the work of both calls -- with and without inner UDF.
--
-- Insert a value into the list (into the B+ Tree).  We will have both a
-- COMPACT storage mode and a TREE storage mode.  When in COMPACT mode,
-- the root node holds the list directly (linear search and append).
-- When in Tree mode, the root node holds the top level of the tree.
-- Parms:
-- (*) topRec:
-- (*) ldtBinName:
-- (*) newValue:
-- (*) createSpec:
-- (*) src: Sub-Rec Context - Needed for repeated calls from caller
-- =======================================================================
function llist.add( topRec, ldtBinName, newValue, createSpec, src )
  GP=B and trace("\n\n >>>>>>>>> API[ LLIST ADD ] <<<<<<<<<<< \n");
  local meth = "llist.add()";
  GP=E and trace("[ENTER]<%s:%s>LLIST BIN(%s) NwVal(%s) createSpec(%s) src(%s)",
    MOD, meth, tostring(ldtBinName), tostring( newValue ),
    tostring(createSpec), tostring(src));

  local rc = 0;
  -- Validate the topRec, the bin and the map.  If anything is weird, then
  -- this will kick out with a long jump error() call.
  -- This function does not build, save or update.  It only checks.
  -- Check to see if LDT Structure (or anything) is already there.  If there
  -- is an LDT BIN present, then it MUST be valid.
  validateRecBinAndMap( topRec, ldtBinName, false );

  -- If the record does not exist, or the BIN does not exist, then we must
  -- create it and initialize the LDT map. Otherwise, use it.
  if( topRec[ldtBinName] == nil ) then
    GP=F and trace("[INFO]<%s:%s>LLIST CONTROL BIN does not Exist:Creating",
         MOD, meth );

    -- set up our new LDT Bin
    setupLdtBin( topRec, ldtBinName, createSpec );
  end

  local ldtCtrl = topRec[ ldtBinName ];
  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];

  GD=DEBUG and trace("[DEBUG]<%s:%s> LDT Summary(%s)", MOD, meth,
    ldtSummaryString(ldtCtrl));

  -- Set up the Read/Write Functions (KeyFunction, Transform, Untransform)
  G_KeyFunction = ldt_common.setKeyFunction( ldtMap, 1, G_KeyFunction ); 
  G_Filter, G_UnTransform = ldt_common.setReadFunctions( ldtMap, nil, nil );
  G_Transform = ldt_common.setWriteFunctions( ldtMap );
  
  -- DESIGN NOTE: All "outer" functions, like this one, will create a
  -- "subrecContext" object, which will hold all of the open subrecords.
  -- The key will be the DigestString, and the value will be the subRec
  -- pointer.  At the end of the call, we will iterate thru the subrec
  -- context and close all open subrecords.  Note that we may also need
  -- to mark them dirty -- but for now we'll update them in place (as needed),
  -- but we won't close them until the end.
  -- This is needed for both the "convertList()" call, which makes multiple
  -- calls to the treeInsert() function (which opens and closes subrecs) and
  -- the regular treeInsert() call, which, in the case of a split, may do
  -- a lot of opens/closes of nodes and leaves.
  if ( src == nil ) then
    src = ldt_common.createSubRecContext();
  end

  -- When we're in "Compact" mode, before each insert, look to see if 
  -- it's time to turn our single list into a tree.
  local totalCount = ldtMap[R_TotalCount];
  GP=F and trace("[NOTICE!!]<%s:%s>Checking State for Conversion", MOD, meth );
  GP=F and trace("[NOTICE!!]<%s:%s>State(%s) C val(%s) TotalCount(%d)", MOD,
    meth, tostring(ldtMap[R_StoreState]), tostring(SS_COMPACT), totalCount);

  -- We're going to base the conversion on TotalCount, not ItemCount, since
  -- it's really the amount of space we're using (empty slots and full slots)
  -- not just the full slots (which would be ItemCount).
  if(( ldtMap[R_StoreState] == SS_COMPACT ) and
     ( totalCount >= ldtMap[R_Threshold] )) 
  then
    newConvertList(src, topRec, ldtBinName, ldtCtrl );
  end
 
  -- Call our local multi-purpose insert() to do the job.(Update Stats)
  localInsert(src, topRec, ldtCtrl, newValue, true );

  -- This is a debug "Tree Print" 
  GD=DEBUG and printTree( src, topRec, ldtBinName );

  -- Close ALL of the subrecs that might have been opened (just the read-only
  -- ones).  All of the dirty ones will stay open.
  rc = ldt_common.closeAllSubRecs( src );
  if( rc < 0 ) then
    warn("[ERROR]<%s:%s> Problems in closeAllSubRecs() SRC(%s)",
      MOD, meth, tostring( src ));
    error( ldte.ERR_SUBREC_CLOSE );
  end

  -- All done, store the record
  -- With recent changes, we know that the record is now already created
  -- so all we need to do is perform the update (no create needed).
  GP=F and trace("[DEBUG]:<%s:%s>:Update Record()", MOD, meth );
  rc = aerospike:update( topRec );
  if ( rc ~= 0 ) then
    warn("[ERROR]<%s:%s>TopRec Update Error rc(%s)",MOD,meth,tostring(rc));
    error( ldte.ERR_TOPREC_UPDATE );
  end 

  GP=E and trace("[EXIT]:<%s:%s> rc(%d)", MOD, meth, rc );
  return rc;
end -- function llist.add()

-- =======================================================================
-- llist.add_all() - Iterate thru the list and call llist.add on each element.
-- =======================================================================
-- Parms:
-- (*) topRec:
-- (*) ldtBinName:
-- (*) valueList
-- (*) createSpec:
-- =======================================================================
-- TODO: Convert this to use a COMMON local INSERT() function, not just
-- call llist.add() and do all of its validation each time.
-- =======================================================================
function llist.add_all( topRec, ldtBinName, valueList, createSpec, src )
  GP=B and trace("\n\n >>>>>>>>> API[ LLIST ADD_ALL ] <<<<<<<<<<< \n");

  local meth = "insert_all()";
  GP=E and trace("[ENTER]:<%s:%s>BIN(%s) valueList(%s) createSpec(%s)",
  MOD, meth, tostring(ldtBinName), tostring(valueList), tostring(createSpec));
  
  
  -- DESIGN NOTE: All "outer" functions, like this one, will create a
  -- "subrecContext" object, which will hold all of the open subrecords.
  -- The key will be the DigestString, and the value will be the subRec
  -- pointer.  At the end of the call, we will iterate thru the subrec
  -- context and close all open subrecords.  Note that we may also need
  -- to mark them dirty -- but for now we'll update them in place (as needed),
  -- but we won't close them until the end.
  -- This is needed for both the "convertList()" call, which makes multiple
  -- calls to the treeInsert() function (which opens and closes subrecs) and
  -- the regular treeInsert() call, which, in the case of a split, may do
  -- a lot of opens/closes of nodes and leaves.
  if ( src == nil ) then
    src = ldt_common.createSubRecContext();
  end

  local rc = 0;
  if( valueList ~= nil and list.size(valueList) > 0 ) then
    local listSize = list.size( valueList );
    for i = 1, listSize, 1 do
      rc = llist.add( topRec, ldtBinName, valueList[i], createSpec, src );
      if( rc < 0 ) then
        warn("[ERROR]<%s:%s> Problem Inserting Item #(%d) [%s]", MOD, meth, i,
          tostring( valueList[i] ));
        error(ldte.ERR_INSERT);
      end
    end -- for each value in the list
  else
    warn("[ERROR]<%s:%s> Invalid Input Value List(%s)",
      MOD, meth, tostring(valueList));
    error(ldte.ERR_INPUT_PARM);
  end
  
  return rc;
end -- function llist.add_all()

-- =======================================================================
-- llist.find() - Locate all items corresponding to searchKey
-- =======================================================================
-- Return all objects that correspond to this SINGLE key value.
--
-- Note that a key of "nil" will search to the leftmost part of the tree
-- and then will match ALL keys, so it is effectively a scan.
-- Parms:
-- (*) topRec:
-- (*) ldtBinName:
-- (*) key
-- (*) userModule
-- (*) func:
-- (*) fargs:
-- (*) src: Sub-Rec Context - Needed for repeated calls from caller
-- Result:
--
-- =======================================================================
-- The find() function can do multiple things. 
-- =======================================================================
function llist.find(topRec,ldtBinName,key,userModule,filter,fargs, src)
  GP=B and trace("\n\n >>>>>>>>>>>> API[ LLIST FIND ] <<<<<<<<<<< \n");
  local meth = "llist.find()";
  GP=E and trace("[ENTER]<%s:%s> bin(%s) key(%s) UM(%s) Fltr(%s) Fgs(%s)",
    MOD, meth, tostring(ldtBinName), tostring(key), tostring(userModule),
    tostring(filter), tostring(fargs));

  local rc = 0;
  -- Define our return list
  local resultList = list();
  
  -- Validate the topRec, the bin and the map.  If anything is weird, then
  -- this will kick out with a long jump error() call.
  local ldtCtrl = validateRecBinAndMap( topRec, ldtBinName, true );
  
  -- Extract the property map and control map from the ldt bin list.
  local ldtCtrl = topRec[ldtBinName];
  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];

  -- set up the Read Functions (UnTransform, Filter)
  G_KeyFunction = ldt_common.setKeyFunction( ldtMap, true, G_KeyFunction ); 
  G_Filter, G_UnTransform =
      ldt_common.setReadFunctions( ldtMap, userModule, filter );
  G_FunctionArgs = fargs;

  -- Create our subrecContext, which tracks all open SubRecords during
  -- the call.  Then, allows us to close them all at the end.
  if ( src == nil ) then
    src = ldt_common.createSubRecContext();
  end

  local resultA;
  local resultB;

  -- If our state is "compact", do a simple list search, otherwise do a
  -- full tree search.
  if( ldtMap[R_StoreState] == SS_COMPACT ) then 
    -- Do the COMPACT LIST SEARCH
    local objectList = ldtMap[R_CompactList];
    local resultMap = searchObjectList( ldtMap, objectList, key );
    if( resultMap.Status == ERR_OK and resultMap.Found == true ) then
      local position = resultMap.Position;
      resultA, resultB = 
          listScan(objectList, position, ldtMap, resultList, key, CR_EQUAL);
      GP=F and trace("[DEBUG]<%s:%s> Scan Compact List:Res(%s) A(%s) B(%s)",
        MOD, meth, tostring(resultList), tostring(resultA), tostring(resultB));
      if( resultB < 0 ) then
        warn("[ERROR]<%s:%s> Problems with Scan: Key(%s), List(%s)", MOD, meth,
          tostring( key ), tostring( objectList ) );
        error( ldte.ERR_INTERNAL );
      end
    else
      warn("[ERROR]<%s:%s> Search Not Found: Key(%s), List(%s)", MOD, meth,
        tostring( key ), tostring( objectList ) );
      error( ldte.ERR_NOT_FOUND );
    end
  else
    -- Do the TREE Search
    GP=F and trace("[DEBUG]<%s:%s> Searching Tree", MOD, meth );
    local sp = createSearchPath(ldtMap);
    rc = treeSearch( src, topRec, sp, ldtCtrl, key );
    if( rc == ST_FOUND ) then
      rc = treeScan( src, resultList, topRec, sp, ldtCtrl, key, CR_EQUAL);
      if( rc < 0 or list.size( resultList ) == 0 ) then
          warn("[ERROR]<%s:%s> Tree Scan Problem: RC(%d) after a good search",
            MOD, meth, rc );
      end
    else
      warn("[ERROR]<%s:%s> Tree Search Not Found: Key(%s)", MOD, meth,
        tostring( key ) );
      error( ldte.ERR_NOT_FOUND );
    end
  end -- tree search

  -- Close ALL of the subrecs that might have been opened
  rc = ldt_common.closeAllSubRecs( src );
  if( rc < 0 ) then
    warn("[EARLY EXIT]<%s:%s> Problem closing subrec in search", MOD, meth );
    error( ldte.ERR_SUBREC_CLOSE );
  end

  GP=F and trace("[EXIT]: <%s:%s>: Search Key(%s) Result: Sz(%d) List(%s)",
    MOD, meth, tostring(key), list.size(resultList), tostring(resultList));
  
  -- We have either jumped out of here via error() function call, or if
  -- we got this far, then we are supposed to have a valid resultList.
  return resultList;
end -- function llist.find() 

-- (*) Object = llist.find_min(topRec,ldtBinName)
-- (*) Object = llist.find_max(topRec,ldtBinName)

-- =======================================================================
-- llist.find_min() - Locate the MINIMUM item and return it
-- =======================================================================
-- Drop down to the Left Leaf and return the FIRST element.
-- all of the work.
-- Parms:
-- (*) topRec:
-- (*) ldtBinName:
-- (*) src: Sub-Rec Context - Needed for repeated calls from caller
-- Result:
-- Success: Object is returned
-- Error: Error Code/String
-- =======================================================================
function llist.find_min( topRec,ldtBinName, src)
  GP=B and trace("\n\n >>>>>>>>>>>> API[ LLIST FIND MIN ] <<<<<<<<<<< \n");
  local meth = "llist.find_min()";
  GP=E and trace("[ENTER]<%s:%s> bin(%s) ", MOD, meth, tostring( ldtBinName));

  local result = treeMin( topRec, ldtBinName, false );

  local rc = 0;
  -- Define our return value;
  local resultValue = "NOT YET IMPLEMENTED";
  
  -- Validate the topRec, the bin and the map.  If anything is weird, then
  -- this will kick out with a long jump error() call.
  local ldtCtrl = validateRecBinAndMap( topRec, ldtBinName, true );
  
  -- Extract the property map and control map from the ldt bin list.
  local ldtCtrl = topRec[ldtBinName];
  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];

  -- If our itemCount is ZERO, then quickly return NIL before we get into
  -- any trouble.
  if( propMap[PM_ItemCount] == 0 ) then
    info("[ATTENTION]<%s:%s> Searching for MIN of EMPTY TREE", MOD, meth );
    return nil;
  end

  -- set up the Read Functions (UnTransform, Filter)
  G_KeyFunction = ldt_common.setKeyFunction( ldtMap, true, G_KeyFunction ); 
  G_Filter, G_UnTransform =
      ldt_common.setReadFunctions( ldtMap, nil, nil );
  G_FunctionArgs = nil;

  -- Init our subrecContext, if necessary.  The SRC tracks all open
  -- SubRecords during the call. Then, allows us to close them all at the end.
  -- For the case of repeated calls from Lua, the caller must pass in
  -- an existing SRC that lives across LDT calls.
  if ( src == nil ) then
    src = ldt_common.createSubRecContext();
  end

  local resultA;
  local resultB;
  local storeObject;

  -- If our state is "compact", just get the first element.
  if( ldtMap[R_StoreState] == SS_COMPACT ) then 
    -- Do the COMPACT LIST SEARCH
    local objectList = ldtMap[R_CompactList];
    -- If we have a transform/untransform, do that here.
    storedObject = objectList[i];
    if( G_UnTransform ~= nil ) then
      resultObject = G_UnTransform( storedObject );
    else
      resultObject = storedObject;
    end
  else
    -- It's a "regular" Tree State, so do the Tree Operation.
    -- Note that "Left-Most" is a special case, where by using a nil key
    -- we automatically go to the "minimal" position.  We can pull
    -- the value from our Search Path (sp) Object.
    GP=F and trace("[DEBUG]<%s:%s> Searching Tree", MOD, meth );
    local sp = createSearchPath(ldtMap);
    rc = treeSearch( src, topRec, sp, ldtCtrl, nil );
    -- We're just going to assume there's a MIN found, given that
    -- there's a non-zero tree present.

    if( rc == ST_FOUND ) then
      rc = treeScan( src, resultList, topRec, sp, ldtCtrl, key, CR_EQUAL );
      if( rc < 0 or list.size( resultList ) == 0 ) then
          warn("[ERROR]<%s:%s> Tree Scan Problem: RC(%d) after a good search",
            MOD, meth, rc );
      end
    else
      warn("[ERROR]<%s:%s> Tree Search Not Found: Key(%s)", MOD, meth,
        tostring( key ) );
      error( ldte.ERR_NOT_FOUND );
    end
  end -- tree search

  -- Close ALL of the subrecs that might have been opened
  rc = ldt_common.closeAllSubRecs( src );
  if( rc < 0 ) then
    warn("[EARLY EXIT]<%s:%s> Problem closing subrec in search", MOD, meth );
    error( ldte.ERR_SUBREC_CLOSE );
  end

  GP=F and trace("[EXIT]: <%s:%s>: Search Key(%s) Result: Sz(%d) List(%s)",
  MOD, meth, tostring(key), list.size(resultList), tostring(resultList));
  
  -- We have either jumped out of here via error() function call, or if
  -- we got this far, then we are supposed to have a valid resultList.
  return resultList;
end -- function llist.find_min() 

-- =======================================================================
-- llist.range() - Locate all items in the range of minKey to maxKey.
-- =======================================================================
-- Do the initial search to find minKey, then perform a scan until maxKey
-- is found.  Return all values that pass any supplied filters.
-- If minKey is null -- scan starts at the LEFTMOST side of the list or tree.
-- If maxKey is null -- scan will continue to the end of the list or tree.
-- Parms:
-- (*) topRec: The Aerospike Top Record
-- (*) ldtBinName: The Bin of the Top Record used for this LDT
-- (*) minKey: The starting value of the range: Nil means neg infinity
-- (*) maxKey: The end value of the range: Nil means infinity
-- (*) userModule: The module possibly holding the user's filter
-- (*) filter: the optional predicate filter
-- (*) fargs: Arguments to the filter
-- (*) src: Sub-Rec Context - Needed for repeated calls from caller
-- Result:
-- Success: resultList holds the result of the range query
-- Error: Error string to outside Lua caller.
-- =======================================================================
function
llist.range(topRec, ldtBinName,minKey,maxKey,userModule,filter,fargs,src)
  GP=B and trace("\n\n >>>>>>>>>>>> API[ LLIST RANGE ] <<<<<<<<<<< \n");
  local meth = "llist.range()";
  GP=E and trace("[ENTER]<%s:%s> bin(%s) minKey(%s) maxKey(%s)", MOD, meth,
      tostring( ldtBinName), tostring(minKey), tostring(maxKey));

  local rc = 0;
  -- Define our return list
  local resultList = list();
  
  -- Validate the topRec, the bin and the map.  If anything is weird, then
  -- this will kick out with a long jump error() call.
  local ldtCtrl = validateRecBinAndMap( topRec, ldtBinName, true );
  
  -- Extract the property map and control map from the ldt bin list.
  local ldtCtrl = topRec[ldtBinName];
  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];

  -- set up the Read Functions (UnTransform, Filter)
  G_KeyFunction = ldt_common.setKeyFunction( ldtMap, true, G_KeyFunction ); 
  G_Filter, G_UnTransform =
      ldt_common.setReadFunctions( ldtMap, userModule, filter );
  G_FunctionArgs = fargs;

  -- Create our subrecContext, which tracks all open SubRecords during
  -- the call.  Then, allows us to close them all at the end.
  if ( src == nil ) then
    src = ldt_common.createSubRecContext();
  end

  local resultA; -- instruction: stop or keep scanning
  local resultB; -- Result: 0: ok,  < 0: error.
  local position;-- location where the item would be (found or not)

  -- If our state is "compact", do a simple list search, otherwise do a
  -- full tree search.
  if( ldtMap[R_StoreState] == SS_COMPACT ) then 
    -- Do the <><><> COMPACT LIST SEARCH <><><>
    local objectList = ldtMap[R_CompactList];
    -- This search only finds the place to start the scan (range scan), it does
    -- NOT need to find the first element.
    local resultMap = searchObjectList( ldtMap, objectList, minKey );
    position = resultMap.Position;

    if( resultMap.Status == ERR_OK and resultMap.Found == true ) then
      GP=F and trace("[FOUND]<%s:%s> CL: Found first element at (%d)",
        MOD, meth, position);
    end

    resultA, resultB = 
        listScan(objectList,position,ldtMap,resultList,maxKey,CR_GREATER_THAN);
    GP=F and trace("[DEBUG]<%s:%s> Scan Compact List:Res(%s) A(%s) B(%s)",
      MOD, meth, tostring(resultList), tostring(resultA), tostring(resultB));
    if( resultB < 0 ) then
      warn("[ERROR]<%s:%s> Problems with Scan: MaxKey(%s), List(%s)", MOD,
        meth, tostring( maxKey ), tostring( objectList ) );
      error( ldte.ERR_INTERNAL );
    end

  else
    -- Do the <><><> TREE Search <><><>
    GP=F and trace("[DEBUG]<%s:%s> Searching Tree", MOD, meth );
    local sp = createSearchPath(ldtMap);
    rc = treeSearch( src, topRec, sp, ldtCtrl, minKey );
    -- Recall that we don't need to find the first element for a Range Scan.
    -- The search ONLY finds the place where we start the scan.
    if( rc == ST_FOUND ) then
      GP=F and trace("[FOUND]<%s:%s> TS: Found: SearchPath(%s)", MOD, meth,
        tostring( sp ));
    end

    rc = treeScan(src,resultList,topRec,sp,ldtCtrl,maxKey,CR_GREATER_THAN);
    if( rc < 0 or list.size( resultList ) == 0 ) then
        warn("[ERROR]<%s:%s> Tree Scan Problem: RC(%d) after a good search",
          MOD, meth, rc );
    end
  end -- tree search

  -- Close ALL of the subrecs that might have been opened
  rc = ldt_common.closeAllSubRecs( src );
  if( rc < 0 ) then
    warn("[EARLY EXIT]<%s:%s> Problem closing subrec in search", MOD, meth );
    error( ldte.ERR_SUBREC_CLOSE );
  end

  GP=F and trace("[EXIT]: <%s:%s>: Search Key(%s) Returns Sz(%d) List(%s)",
    MOD, meth, tostring(key), list.size(resultList), tostring(resultList));
  
  -- We have either jumped out of here via error() function call, or if
  -- we got this far, then we are supposed to have a valid resultList.
  return resultList;
end -- function llist.range() 

-- =======================================================================
-- scan(): Return all elements
-- filter(): Pass all elements thru the filter and return all that qualify.
-- =======================================================================
-- Find with key==nil will start the beginning of the list and will
-- match all elements.
-- Return:
-- Success: the Result List.
-- Error: Error String to outer Lua Caller (long jump)
-- =======================================================================
function llist.scan( topRec, ldtBinName, src )
  GP=B and trace("\n\n  >>>>>>>>>>>> API[ SCAN ] <<<<<<<<<<<<<< \n");
  local meth = "scan()";
  GP=E and trace("[ENTER]<%s:%s> BIN(%s)", MOD, meth, tostring(ldtBinName) );

  return llist.find( topRec, ldtBinName,nil, nil, nil, nil, src );
end -- llist.scan()

function llist.filter( topRec, ldtBinName, userModule, filter, fargs, src )
  GP=F and trace("\n\n  >>>>>>>>>>>> API[ FILTER ]<<<<<<<<<<< \n");

  local meth = "filter()";
  GP=E and trace("[ENTER]<%s:%s> BIN(%s) module(%s) func(%s) fargs(%s)",
    MOD, meth, tostring(ldtBinName), tostring(userModule),
    tostring(filter), tostring(fargs));

  return llist.find( topRec, ldtBinName, nil, userModule, filter, fargs, src );
end -- llist.filter()

-- ======================================================================
-- llist.remove() -- remove the item(s) corresponding to key.
-- ======================================================================
-- Delete the specified item(s).
--
-- Parms 
-- (1) topRec: the user-level record holding the LDT Bin
-- (2) LdtBinName
-- (3) key: The key we'll search for
-- (4) src: Sub-Rec Context - Needed for repeated calls from caller
-- ======================================================================
function llist.remove( topRec, ldtBinName, key, src )
  GP=F and trace("\n\n  >>>>>>>>>>>> API[ REMOVE ]<<<<<<<<<<< \n");
  local meth = "llist.remove()";
  local rc = 0;

  GP=E and trace("[ENTER]<%s:%s>ldtBinName(%s) key(%s)",
      MOD, meth, tostring(ldtBinName), tostring(key));

  -- Validate the topRec, the bin and the map.  If anything is weird, then
  -- this will kick out with a long jump error() call.
  local ldtCtrl = validateRecBinAndMap( topRec, ldtBinName, true );
  
  -- Extract the property map and control map from the ldt bin list.
  ldtCtrl = topRec[ ldtBinName ];
  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];
  --
  -- Set up the Read Functions (KeyFunction, Transform, Untransform)
  G_KeyFunction = ldt_common.setKeyFunction( ldtMap, true, G_KeyFunction ); 
  G_Filter, G_UnTransform = ldt_common.setReadFunctions( ldtMap, nil, nil );

  -- Init our subrecContext, if necessary.  The SRC tracks all open
  -- SubRecords during the call. Then, allows us to close them all at the end.
  -- For the case of repeated calls from Lua, the caller must pass in
  -- an existing SRC that lives across LDT calls.
  if ( src == nil ) then
    src = ldt_common.createSubRecContext();
  end

  -- If our state is "compact", do a simple list delete, otherwise do a
  -- real tree delete.
  if( ldtMap[R_StoreState] == SS_COMPACT ) then 
    -- Search the compact list, find the location, then delete it.
    GP=F and trace("[NOTICE]<%s:%s> Using COMPACT DELETE", MOD, meth);
    local objectList = ldtMap[R_CompactList];
    resultMap = searchObjectList( ldtMap, objectList, key );
    if( resultMap.Status == ERR_OK and resultMap.Found == true ) then
      ldtMap[R_CompactList] =
        ldt_common.listDelete(objectList, resultMap.Position);
    else
      error( ldte.ERR_NOT_FOUND );
    end
  else
    GP=F and trace("[NOTICE]<%s:%s> Using >>>  TREE DELETE  <<<", MOD, meth);
    rc = treeDelete(src, topRec, ldtCtrl, key );
  end

  -- update stats if successful
  if( rc >= 0 ) then -- Update Stats if success
    local itemCount = propMap[PM_ItemCount];
    local totalCount = ldtMap[R_TotalCount];
    propMap[PM_ItemCount] = itemCount - 1; 
    ldtMap[R_TotalCount] = totalCount - 1;
    GP=F and trace("[DEBUG]: <%s:%s> itemCount(%d)", MOD, meth, itemCount );
    rc = 0;
  end
  topRec[ ldtBinName ] = ldtCtrl;
  record.set_flags(topRec, ldtBinName, BF_LDT_BIN );--Must set every time

  -- Validate results -- if anything bad happened, then the record
  -- probably did not change -- we don't need to udpate.
  if( rc == 0 ) then
    -- Close ALL of the subrecs that might have been opened
    rc = ldt_common.closeAllSubRecs( src );
    if( rc < 0 ) then
      warn("[ERROR]<%s:%s> Problems closing subrecs in delete", MOD, meth );
      error( ldte.ERR_SUBREC_CLOSE );
    end

    -- All done, store the record
    GP=F and trace("[DEBUG]:<%s:%s>:Update Record()", MOD, meth );

    -- Update the Top Record.  Not sure if this returns nil or ZERO for ok,
    -- so just turn any NILs into zeros.
    rc = aerospike:update( topRec );
    if ( rc ~= 0 ) then
      warn("[ERROR]<%s:%s>TopRec Update Error rc(%s)",MOD,meth,tostring(rc));
      error( ldte.ERR_TOPREC_UPDATE );
    end 

    GP=F and trace("[Normal EXIT]:<%s:%s> Return(0)", MOD, meth );
    return 0;
  else
    GP=F and trace("[ERROR EXIT]:<%s:%s> Return(%s)", MOD, meth,tostring(rc));
    error( ldte.ERR_DELETE );
  end
end -- function llist.remove()


-- ========================================================================
-- llist.destroy(): Remove the LDT entirely from the record.
-- ========================================================================
-- Release all of the storage associated with this LDT and remove the
-- control structure of the bin.  If this is the LAST LDT in the record,
-- then ALSO remove the HIDDEN LDT CONTROL BIN.
--
-- Parms:
-- (1) topRec: the user-level record holding the LDT Bin
-- (2) ldtBinName: The name of the LDT Bin
-- (3) src: Sub-Rec Context - Needed for repeated calls from caller
-- Result:
--   res = 0: all is well
--   res = -1: Some sort of error
-- ========================================================================
-- NOTE: This could eventually be moved to COMMON, and be "ldt_destroy()",
-- since it will work the same way for all LDTs.
-- Remove the ESR, Null out the topRec bin.
-- ========================================================================
function llist.destroy( topRec, ldtBinName, src)
  GP=B and trace("\n\n >>>>>>>>> API[ LLIST DESTROY ] <<<<<<<<<< \n");
  local meth = "localLdtDestroy()";
  GP=E and trace("[ENTER]: <%s:%s> Bin(%s)", MOD, meth, tostring(ldtBinName));
  local rc = 0; -- start off optimistic

  -- Validate the BinName before moving forward
  local ldtCtrl = validateRecBinAndMap( topRec, ldtBinName, true );

  -- Extract the property map and LDT control map from the LDT bin list.
  -- local ldtCtrl = topRec[ ldtBinName ];
  local propMap = ldtCtrl[1];

  GD=DEBUG and trace("[STATUS]<%s:%s> propMap(%s) LDT Summary(%s)", MOD, meth,
    tostring( propMap ), ldtSummaryString( ldtCtrl ));

  -- Init our subrecContext, if necessary.  The SRC tracks all open
  -- SubRecords during the call. Then, allows us to close them all at the end.
  -- For the case of repeated calls from Lua, the caller must pass in
  -- an existing SRC that lives across LDT calls.
  if ( src == nil ) then
    src = ldt_common.createSubRecContext();
  end

  -- Get the ESR and delete it -- if it exists.  If we have ONLY an initial
  -- compact list, then the ESR will be ZERO.
  local esrDigest = propMap[PM_EsrDigest];
  if( esrDigest ~= nil and esrDigest ~= 0 ) then
    local esrDigestString = tostring(esrDigest);
    GP=F and trace("[SUBREC OPEN]<%s:%s> Digest(%s)", MOD, meth, esrDigestString );
    local esrRec = ldt_common.openSubRec(src, topRec, esrDigestString );
    if( esrRec ~= nil ) then
      rc = ldt_common.removeSubRec( src, esrDigestString );
      if( rc == nil or rc == 0 ) then
        GP=F and trace("[STATUS]<%s:%s> Successful CREC REMOVE", MOD, meth );
      else
        warn("[ESR DELETE ERROR]<%s:%s>RC(%d) Bin(%s)", MOD, meth, rc, ldtBinName);
        error( ldte.ERR_SUBREC_DELETE );
      end
    else
      warn("[ESR DELETE ERROR]<%s:%s> ERROR on ESR Open", MOD, meth );
    end
  else
    info("[INFO]<%s:%s> LDT ESR is not yet set, so remove not needed. Bin(%s)",
    MOD, meth, ldtBinName );
  end

  topRec[ldtBinName] = nil;

  -- Get the Common LDT (Hidden) bin, and update the LDT count.  If this
  -- is the LAST LDT in the record, then remove the Hidden Bin entirely.
  local recPropMap = topRec[REC_LDT_CTRL_BIN];
  if( recPropMap == nil or recPropMap[RPM_Magic] ~= MAGIC ) then
    warn("[INTERNAL ERROR]<%s:%s> Prop Map for LDT Hidden Bin invalid",
      MOD, meth );
    error( ldte.ERR_BIN_DAMAGED );
  end
  local ldtCount = recPropMap[RPM_LdtCount];
  if( ldtCount <= 1 ) then
    -- Remove this bin
    topRec[REC_LDT_CTRL_BIN] = nil;
  else
    recPropMap[RPM_LdtCount] = ldtCount - 1;
    topRec[REC_LDT_CTRL_BIN] = recPropMap;
    record.set_flags(topRec, REC_LDT_CTRL_BIN, BF_LDT_HIDDEN );
  end
  
  -- Update the Top Record.  Not sure if this returns nil or ZERO for ok,
  -- so just turn any NILs into zeros.
  rc = aerospike:update( topRec );
  if ( rc ~= 0 ) then
    warn("[ERROR]<%s:%s>TopRec Update Error rc(%s)",MOD,meth,tostring(rc));
    error( ldte.ERR_TOPREC_UPDATE );
  end 

  GP=F and trace("[Normal EXIT]:<%s:%s> Return(0)", MOD, meth );
  return 0;
end -- llist.destroy()

-- ========================================================================
-- llist.size() -- return the number of elements (item count) in the set.
-- ========================================================================
-- Parms:
-- (1) topRec: the user-level record holding the LDT Bin
-- (2) ldtBinName: The name of the LDT Bin
-- Result:
--   SUCCESS: The number of elements in the LDT
--   ERROR: The Error code via error() call
-- ========================================================================
function llist.size( topRec, ldtBinName )
  GP=B and trace("\n\n >>>>>>>>> API[ LLIST SIZE ] <<<<<<<<<\n");
  local meth = "llist.size()";
  GP=E and trace("[ENTER1]: <%s:%s> Bin(%s)", MOD, meth, tostring(ldtBinName));

  -- Validate the topRec, the bin and the map.  If anything is weird, then
  -- this will kick out with a long jump error() call.
  local ldtCtrl = validateRecBinAndMap( topRec, ldtBinName, true );

  -- Extract the property map and control map from the ldt bin list.
  -- local ldtCtrl = topRec[ ldtBinName ];
  local propMap = ldtCtrl[1];
  local itemCount = propMap[PM_ItemCount];

  GP=F and trace("[EXIT]: <%s:%s> : size(%d)", MOD, meth, itemCount );

  return itemCount;
end -- llist.size()

-- ========================================================================
-- llist.config() -- return the config settings
-- ========================================================================
-- Parms:
-- (1) topRec: the user-level record holding the LDT Bin
-- (2) ldtBinName: The name of the LDT Bin
-- Result:
--   SUCCESS: The MAP of the config.
--   ERROR: The Error code via error() call
-- ========================================================================
function llist.config( topRec, ldtBinName )
  GP=B and trace("\n\n >>>>>>>>>>> API[ LLIST CONFIG ] <<<<<<<<<<<< \n");

  local meth = "llist.config()";
  GP=E and trace("[ENTER1]: <%s:%s> ldtBinName(%s)",
    MOD, meth, tostring(ldtBinName));

  -- Validate the topRec, the bin and the map.  If anything is weird, then
  -- this will kick out with a long jump error() call.
  local ldtCtrl = validateRecBinAndMap( topRec, ldtBinName, true );

  -- info("POST VALIDATE");

  local config = ldtSummary( ldtCtrl );

  -- info("POST SUMMARY");

  GP=F and trace("[EXIT]: <%s:%s> : config(%s)",
    MOD, meth, tostring(config) );

  return config;
end -- function llist.config()

-- ========================================================================
-- llist.get_capacity() -- return the current capacity setting for this LDT
-- Capacity is in terms of Number of Elements.
-- Parms:
-- (1) topRec: the user-level record holding the LDT Bin
-- (2) ldtBinName: The name of the LDT Bin
-- Result:
--   rc >= 0  (the current capacity)
--   rc < 0: Aerospike Errors
-- ========================================================================
function llist.get_capacity( topRec, ldtBinName )
  GP=B and trace("\n\n  >>>>>>>> API[ GET CAPACITY ] <<<<<<<<<<<<<<<<<< \n");
  local meth = "llist.get_capacity()";

  GP=E and trace("[ENTER]: <%s:%s> ldtBinName(%s)",
    MOD, meth, tostring(ldtBinName));

  -- validate the topRec, the bin and the map.  If anything is weird, then
  -- this will kick out with a long jump error() call.
  local ldtCtrl = validateRecBinAndMap( topRec, ldtBinName, true );

  local ldtCtrl = topRec[ ldtBinName ];
  -- Extract the property map and LDT control map from the LDT bin list.
  local ldtMap = ldtCtrl[2];
  local capacity = ldtMap[M_StoreLimit];
  if( capacity == nil ) then
    capacity = 0;
  end

  GP=E and trace("[EXIT]: <%s:%s> : size(%d)", MOD, meth, capacity );

  return capacity;
end -- function llist.get_capacity()

-- ========================================================================
-- llist.set_capacity() -- set the current capacity setting for this LDT
-- ========================================================================
-- Parms:
-- (*) topRec: the user-level record holding the LDT Bin
-- (*) ldtBinName: The name of the LDT Bin
-- (*) capacity: the new capacity (in terms of # of elements)
-- Result:
--   rc >= 0  (the current capacity)
--   rc < 0: Aerospike Errors
-- ========================================================================
function llist.set_capacity( topRec, ldtBinName, capacity )
  GP=B and trace("\n\n  >>>>>>>> API[ SET CAPACITY ] <<<<<<<<<<<<<<<<<< \n");
  local meth = "llist.set_capacity()";

  GP=E and trace("[ENTER]: <%s:%s> ldtBinName(%s)",
    MOD, meth, tostring(ldtBinName));

  -- validate the topRec, the bin and the map.  If anything is weird, then
  -- this will kick out with a long jump error() call.
  local ldtCtrl = validateRecBinAndMap( topRec, ldtBinName, true );

  local ldtCtrl = topRec[ ldtBinName ];
  -- Extract the property map and LDT control map from the LDT bin list.
  local ldtMap = ldtCtrl[2];
  if( capacity ~= nil and type(capacity) == "number" and capacity >= 0 ) then
    ldtMap[M_StoreLimit] = capacity;
  else
    warn("[ERROR]<%s:%s> Bad Capacity Value(%s)",MOD,meth,tostring(capacity));
    error( ldte.ERR_INTERNAL );
  end

  GP=E and trace("[EXIT]: <%s:%s> : new size(%d)", MOD, meth, capacity );

  return 0;
end -- function llist.set_capacity()

-- ========================================================================
-- llist.dump(): Debugging/Tracing mechanism -- show the WHOLE tree.
-- ========================================================================
-- ========================================================================
function llist.dump( topRec, ldtBinName, src )
  GP=B and trace("\n\n >>>>>>>>> API[ LLIST DUMP ] <<<<<<<<<< \n");
  if( src == nil ) then
    src = ldt_common.createSubRecContext();
  end
  printTree( src, topRec, ldtBinName );
  return 0;
end -- llist.dump()

-- ======================================================================
-- This is needed to export the function table for this module
-- Leave this statement at the end of the module.
-- ==> Define all functions before this end section.
-- ======================================================================
return llist;

-- ========================================================================
--   _      _     _____ _____ _____ 
--  | |    | |   |_   _/  ___|_   _|
--  | |    | |     | | \ `--.  | |  
--  | |    | |     | |  `--. \ | |  
--  | |____| |_____| |_/\__/ / | |  
--  \_____/\_____/\___/\____/  \_/   (LIB)
--                                  
-- ========================================================================
-- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> --

