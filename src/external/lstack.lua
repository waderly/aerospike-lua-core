-- Large Stack Object (LSTACK) Operations.

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
-- <<  LSTACK Main Functions >>
-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- ======================================================================
-- The following external functions are defined in the LSTACK module:
--
-- (*) Status = push( topRec, ldtBinName, newValue, userModule )
-- (*) Status = push_all( topRec, ldtBinName, valueList, userModule )
-- (*) List   = peek( topRec, ldtBinName, peekCount ) 
-- (*) List   = pop( topRec, ldtBinName, popCount ) 
-- (*) List   = scan( topRec, ldtBinName )
-- (*) List   = filter( topRec, ldtBinName, peekCount,userModule,filter,fargs)
-- (*) Status = destroy( topRec, ldtBinName )
-- (*) Number = size( topRec, ldtBinName )
-- (*) Map    = get_config( topRec, ldtBinName )
-- (*) Status = set_capacity( topRec, ldtBinName, new_capacity)
-- (*) Status = get_capacity( topRec, ldtBinName )
-- ======================================================================
-- Reference the LSTACK LDT Library Module
local lstack = require('ldt/lib_lstack');

-- ======================================================================
-- || create        || (deprecated)
-- || lstack_create || (deprecated)
-- ======================================================================
-- Create/Initialize a Stack structure in a bin, using a single LSO
-- bin, using User's name, but Aerospike TYPE (AS_LSO)
--
-- Notice that the "createSpec" can be either the old style map or the
-- new style user modulename.
--
-- Parms
-- (1) topRec: the user-level record holding the LSO Bin
-- (2) ldtBinName: The name of the LSO Bin
-- (3) createSpec: The map (not list) of create parameters
-- Result:
--   rc = 0: ok
--   rc < 0: Aerospike Errors
-- ========================================================================
-- NEW EXTERNAL FUNCTIONS
function create( topRec, ldtBinName, createSpec )
  return lstack.create( topRec, ldtBinName, createSpec );
end

-- OLD EXTERNAL FUNCTIONS
function lstack_create( topRec, ldtBinName, createSpec )
  return lstack.create( topRec, ldtBinName, createSpec );
end

-- =======================================================================
-- push()
-- lstack_push()
-- =======================================================================
-- Push a value on the stack, with the optional parm to set the LDT
-- configuration in case we have to create the LDT before calling the push.
-- Notice that the "createSpec" can be either the old style map or the
-- new style user modulename.
-- These are the globally visible calls -- that call the local UDF to do
-- all of the work.
-- =======================================================================
-- NEW EXTERNAL FUNCTIONS
function push( topRec, ldtBinName, newValue, createSpec )
  return lstack.push( topRec, ldtBinName, newValue, createSpec, nil );
end -- push()

function create_and_push( topRec, ldtBinName, newValue, createSpec )
  return lstack.push( topRec, ldtBinName, newValue, createSpec, nil );
end -- create_and_push()

-- OLD EXTERNAL FUNCTIONS
function lstack_push( topRec, ldtBinName, newValue, createSpec )
  return lstack.push( topRec, ldtBinName, newValue, createSpec, nil );
end -- end lstack_push()

function lstack_create_and_push( topRec, ldtBinName, newValue, createSpec )
  return lstack.push( topRec, ldtBinName, newValue, createSpec, nil );
end -- lstack_create_and_push()

-- =======================================================================
-- Stack Push ALL
-- =======================================================================
-- Iterate thru the list and call localStackPush on each element
-- Notice that the "createSpec" can be either the old style map or the
-- new style user modulename.
-- =======================================================================
-- NEW EXTERNAL FUNCTIONS
function push_all( topRec, ldtBinName, valueList, createSpec )
  return lstack.push_all( topRec, ldtBinName, valueList, createSpec, nil );
end

-- OLD EXTERNAL FUNCTIONS
function lstack_push_all( topRec, ldtBinName, valueList, createSpec )
  return lstack.push_all( topRec, ldtBinName, valueList, createSpec, nil );
end

-- =======================================================================
-- peek() -- with and without filters
-- lstack_peek() -- with and without filters
--
-- These are the globally visible calls -- that call the local UDF to do
-- all of the work.
-- NOTE: Any parameter that might be printed (for trace/debug purposes)
-- must be protected with "tostring()" so that we do not encounter a format
-- error if the user passes in nil or any other incorrect value/type.
-- =======================================================================
-- NEW EXTERNAL FUNCTIONS
function peek( topRec, ldtBinName, peekCount )
  return lstack.peek( topRec, ldtBinName, peekCount, nil, nil, nil, nil );
end -- peek()

function filter( topRec, ldtBinName, peekCount, userModule, filter, fargs )
  return lstack.peek(topRec,ldtBinName,peekCount,userModule,filter,fargs, nil );
end -- peek_then_filter()

-- OLD EXTERNAL FUNCTIONS (didn't have userModule in the first version)
function lstack_peek( topRec, ldtBinName, peekCount )
  return lstack.peek( topRec, ldtBinName, peekCount, nil, nil, nil, nil );
end -- lstack_peek()

-- OLD EXTERNAL FUNCTIONS (didn't have userModule in the first version)
function lstack_peek_then_filter( topRec, ldtBinName, peekCount, filter, fargs )
  return lstack.peek( topRec, ldtBinName, peekCount, nil, filter, fargs, nil );
end -- lstack_peek_then_filter()


-- =======================================================================
-- scan() -- without filters (just get everything)
--
-- These are the globally visible calls -- that call the local UDF to do
-- all of the work.
-- =======================================================================
function scan( topRec, ldtBinName )
  return lstack.peek( topRec, ldtBinName, 0, nil, nil, nil, nil );
end -- scan()

-- =======================================================================
-- pop() -- Return and remove values from the top of stack
-- =======================================================================
function pop( topRec, ldtBinName, peekCount, userModule, filter, fargs )
  return lstack.pop(topRec,ldtBinName,peekCount,userModule,filter,fargs, nil );
end -- peek_then_filter()

-- ========================================================================
-- size() -- return the number of elements (item count) in the stack.
-- get_size() -- return the number of elements (item count) in the stack.
-- lstack_size() -- return the number of elements (item count) in the stack.
-- Parms:
-- (1) topRec: the user-level record holding the LSO Bin
-- (2) ldtBinName: The name of the LSO Bin
-- Result:
--   rc >= 0  (the size)
--   rc < 0: Aerospike Errors
-- NOTE: Any parameter that might be printed (for trace/debug purposes)
-- must be protected with "tostring()" so that we do not encounter a format
-- error if the user passes in nil or any other incorrect value/type.
-- ========================================================================
-- NEW EXTERNAL FUNCTIONS
function size( topRec, ldtBinName )
  return lstack.size( topRec, ldtBinName );
end -- function size()

function get_size( topRec, ldtBinName )
  return lstack.size( topRec, ldtBinName );
end -- function get_size()

-- OLD EXTERNAL FUNCTIONS
function lstack_size( topRec, ldtBinName )
  return lstack.size( topRec, ldtBinName );
end -- function get_size()

-- ========================================================================
-- get_capacity() -- return the current capacity setting for LSTACK.
-- lstack_get_capacity() -- return the current capacity setting for LSTACK.
-- Parms:
-- (1) topRec: the user-level record holding the LSO Bin
-- (2) ldtBinName: The name of the LSO Bin
-- Result:
--   rc >= 0  (the current capacity)
--   rc < 0: Aerospike Errors
-- NOTE: Any parameter that might be printed (for trace/debug purposes)
-- must be protected with "tostring()" so that we do not encounter a format
-- error if the user passes in nil or any other incorrect value/type.
-- ========================================================================
-- NEW EXTERNAL FUNCTIONS
function get_capacity( topRec, ldtBinName )
  return lstack.get_capacity( topRec, ldtBinName );
end

-- OLD EXTERNAL FUNCTIONS
function lstack_get_capacity( topRec, ldtBinName )
  return lstack.get_capacity( topRec, ldtBinName );
end

-- ========================================================================
-- config() -- return the lstack config settings.
-- get_config() -- return the lstack config settings.
-- lstack_get_config() -- return the lstack config settings.
-- Parms:
-- (1) topRec: the user-level record holding the LSO Bin
-- (2) ldtBinName: The name of the LSO Bin
-- Result:
--   res = (when successful) config Map 
--   res = (when error) nil
-- NOTE: Any parameter that might be printed (for trace/debug purposes)
-- must be protected with "tostring()" so that we do not encounter a format
-- error if the user passes in nil or any other incorrect value/type.
-- ========================================================================
-- NEW EXTERNAL FUNCTIONS
function config( topRec, ldtBinName )
  return lstack.config( topRec, ldtBinName );
end

function get_config( topRec, ldtBinName )
  return lstack.config( topRec, ldtBinName );
end

-- OLD EXTERNAL FUNCTIONS
function lstack_config( topRec, ldtBinName )
  return lstack.config( topRec, ldtBinName );
end

-- ========================================================================
-- destroy() -- Remove the LDT entirely from the record.
-- lstack_remove() -- Remove the LDT entirely from the record.
-- ========================================================================
-- Release all of the storage associated with this LDT and remove the
-- control structure of the bin.  If this is the LAST LDT in the record,
-- then ALSO remove the HIDDEN LDT CONTROL BIN.
--
-- Question  -- Reset the record[ldtBinName] to NIL (does that work??)
-- Parms:
-- (1) topRec: the user-level record holding the LSO Bin
-- (2) binName: The name of the LSO Bin
-- Result:
--   res = 0: all is well
--   res = -1: Some sort of error
-- ========================================================================
-- NEW EXTERNAL FUNCTIONS
function destroy( topRec, ldtBinName )
  return lstack.destroy( topRec, ldtBinName, nil );
end -- destroy()

-- OLD EXTERNAL FUNCTIONS
function lstack_remove( topRec, ldtBinName )
  return lstack.destroy( topRec, ldtBinName, nil );
end -- lstack_remove()
-- ========================================================================
-- lstack_set_storage_limit()
-- lstack_set_capacity()
-- set_storage_limit()
-- set_capacity()
-- ========================================================================
-- This is a special command to both set the new storage limit.  It does
-- NOT release storage, however.  That is done either lazily after a 
-- warm/cold insert or with an explit lstack_trim() command.
-- Parms:
-- (*) topRec: the user-level record holding the LSO Bin
-- (*) ldtBinName: The name of the LSO Bin
-- (*) newLimit: The new limit of the number of entries
-- Result:
--   res = 0: all is well
--   res = -1: Some sort of error
-- ========================================================================
-- NEW EXTERNAL FUNCTIONS
function lstack_set_capacity( topRec, ldtBinName, newLimit )
  return lstack.set_capacity( topRec, ldtBinName, newLimit );
end

function set_capacity( topRec, ldtBinName, newLimit )
  return lstack.set_capacity( topRec, ldtBinName, newLimit );
end

-- OLD EXTERNAL FUNCTIONS
function lstack_set_storage_limit( topRec, ldtBinName, newLimit )
  return lstack.set_capacity( topRec, ldtBinName, newLimit );
end

function set_storage_limit( topRec, ldtBinName, newLimit )
  return lstack.set_capacity( topRec, ldtBinName, newLimit );
end

-- ========================================================================
-- MEASUREMENT FUNCTIONS:
-- See how fast we can call a MINIMAL function.
-- (*) one(): just call and return:
-- (*) same(): Return what's passed in to verify the call.
-- ========================================================================
-- one()          -- Just return 1.  This is used for perf measurement.
-- same()         -- Return Val parm.  Used for perf measurement.
-- ========================================================================
-- Do the minimal amount of work -- just return a number so that we
-- can measure the overhead of the LDT/UDF infrastructure.
-- Parms:
-- (1) topRec: the user-level record holding the LSO Bin
-- (2) Val:  Random number val (or nothing)
-- Result:
--   res = 1 or val
-- ========================================================================
function one( topRec, ldtBinName )
  return 1;
end

function same( topRec, ldtBinName, val )
  if( val == nil or type(val) ~= "number") then
    return 1;
  else
    return val;
  end
end

-- ========================================================================
--   _      _____ _____ ___  _____  _   __
--  | |    /  ___|_   _/ _ \/  __ \| | / /
--  | |    \ `--.  | |/ /_\ \ /  \/| |/ / 
--  | |     `--. \ | ||  _  | |    |    \ 
--  | |____/\__/ / | || | | | \__/\| |\  \
--  \_____/\____/  \_/\_| |_/\____/\_| \_/   (EXTERNAL)
--                                        
-- ========================================================================
-- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> --
