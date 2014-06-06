-- Large Map (LMAP) Operations (Last Update 2014.03.10)

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

-- ======================================================================
-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- <<   LMAP Main Functions   >>
-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- ======================================================================
-- The following external functions are defined in the LMAP module:
--
-- * Status = put( topRec, ldtBinName, newName, newValue, userModule) 
-- * Status = put_all( topRec, ldtBinName, nameValueMap, userModule)
-- * List   = get( topRec, ldtBinName, searchName )
-- * List   = scan( topRec, ldtBinName )
-- * List   = filter( topRec, ldtBinName, userModule, filter, fargs )
-- * Object = remove( topRec, ldtBinName, searchName )
-- * Status = destroy( topRec, ldtBinName )
-- * Number = size( topRec, ldtBinName )
-- * Map    = get_config( topRec, ldtBinName )
-- * Status = set_capacity( topRec, ldtBinName, new_capacity)
-- * Status = get_capacity( topRec, ldtBinName )
-- ======================================================================
-- Reference the LMAP LDT Library Module:
local lmap = require('ldt/lib_lmap');
local ldt_common = require('ldt/ldt_common');

-- ======================================================================
-- create() ::  (deprecated)
-- ======================================================================
-- Create/Initialize a Map structure in a bin, using a single LMAP
-- bin, using User's name, but Aerospike TYPE (AS_LMAP)
--
-- The LMAP starts out in "Compact" mode, which allows the first 100 (or so)
-- entries to be held directly in the record -- in the first lmap bin. 
-- Once the first lmap list goes over its item-count limit, we switch to 
-- standard mode and the entries get collated into a single LDR. We then
-- generate a digest for this LDR, hash this digest over N bins of a digest
-- list. 
-- Please refer to lmap_design.lua for details. 
-- 
-- Parameters: 
-- (1) topRec: the user-level record holding the LMAP Bin
-- (2) ldtBinName: The name of the LMAP Bin
-- (3) createSpec: The userModule containing the "adjust_settings()" function
-- Result:
--   rc = 0: ok
--   rc < 0: Aerospike Errors
-- ========================================================================
function create( topRec, ldtBinName, createSpec )
  return lmap.create( topRec, ldtBinName, createSpec );
end -- create()

-- ======================================================================
-- put() -- Insert a Name/Value pair into the LMAP
-- put_all() -- Insert multiple name/value pairs into the LMAP
-- ======================================================================
function put( topRec, ldtBinName, newName, newValue, createSpec )
  return lmap.put( topRec, ldtBinName, newName, newValue, createSpec, nil);
end -- put()

function put_all( topRec, ldtBinName, NameValMap, createSpec )
  return lmap.put_all( topRec, ldtBinName, NameValMap, createSpec, nil);
end -- put_all()

-- ========================================================================
-- get() -- Return a map containing the requested name/value pair.
-- scan() -- Return a map containing ALL name/value pairs.
-- ========================================================================
-- ========================================================================
function get( topRec, ldtBinName, searchName )
  return lmap.get(topRec, ldtBinName, searchName, nil, nil, nil, nil);
end -- get()

function scan( topRec, ldtBinName )
  return lmap.scan(topRec, ldtBinName, nil, nil, nil);
end -- scan()

-- ========================================================================
-- filter() -- Return a map containing all Name/Value pairs that passed
--             thru the supplied filter( fargs ).
-- ========================================================================
function filter( topRec, ldtBinName, userModule, filter, fargs )
  return lmap.scan(topRec, ldtBinName, userModule, filter, fargs, nil);
end -- filter()

-- ========================================================================
-- remove() -- Remove the name/value pair matching <searchName>
-- ========================================================================
function remove( topRec, ldtBinName, searchName )
  return lmap.remove(topRec, ldtBinName, searchName, nil, nil, nil, nil );
end -- remove()

-- ========================================================================
-- destroy() - Entirely obliterate the LDT (record bin value and all)
-- ========================================================================
function destroy( topRec, ldtBinName )
  return lmap.destroy( topRec, ldtBinName, nil );
end -- destroy()

-- ========================================================================
-- size() -- return the number of elements (item count) in the set.
-- ========================================================================
function size( topRec, ldtBinName )
  return lmap.size( topRec, ldtBinName );
end -- size()

-- ========================================================================
-- config()     -- return the config settings
-- get_config() -- return the config settings
-- ========================================================================
function config( topRec, ldtBinName )
  return lmap.config( topRec, ldtBinName );
end -- config()

function get_config( topRec, ldtBinName )
  return lmap.config( topRec, ldtBinName );
end -- get_config()

-- ========================================================================
-- get_capacity() -- return the current capacity setting for this LDT.
-- set_capacity() -- set the current capacity setting for this LDT.
-- ========================================================================
-- Parms:
-- (1) topRec: the user-level record holding the LDT Bin
-- (2) ldtBinName: The name of the LDT Bin
-- Result:
--   rc >= 0  (the current capacity)
--   rc < 0: Aerospike Errors
-- ========================================================================
function get_capacity( topRec, ldtBinName )
  return lmap.get_capacity( topRec, ldtBinName );
end

function set_capacity( topRec, ldtBinName, capacity )
  return lmap.set_capacity( topRec, ldtBinName, capacity );
end

-- ========================================================================
-- ========================================================================
-- ========================================================================

-- <D> <D> <D> -- <D> <D> <D> -- <D> <D> <D> -- <D> <D> <D> -- <D> <D> <D> 
-- Developer Functions
-- (*) dump()
-- <D> <D> <D> -- <D> <D> <D> -- <D> <D> <D> -- <D> <D> <D> -- <D> <D> <D> 
--
-- ========================================================================
-- dump()
-- ========================================================================
-- Dump the full contents of the LDT (structure and all).
--
-- Dump the full contents of the Large Map, with Separate Hash Groups
-- shown in the result. Unlike scan which simply returns the contents of all 
-- the bins, this routine gives a tree-walk through or map walk-through of the
-- entire lmap structure. 
-- Return a LIST of lists -- with Each List marked with it's Hash Name.
-- ========================================================================
function dump( topRec, ldtBinName )
    -- Set up the Sub-Rec Context to track open Sub-Records.
    local src = ldt_common.createSubRecContext();

  return lmap.dump( topRec, ldtBinName, src );
end

-- ========================================================================
--   _     ___  ___  ___  ______ 
--  | |    |  \/  | / _ \ | ___ \
--  | |    | .  . |/ /_\ \| |_/ /
--  | |    | |\/| ||  _  ||  __/ 
--  | |____| |  | || | | || |    
--  \_____/\_|  |_/\_| |_/\_|    (EXTERNAL)
--                               
-- ========================================================================
-- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> --
