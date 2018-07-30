--[[
How to use:

Put all lua files into DatabaseRoot then call ExportDatabaseLocalText( tofile = true, newStringBank = false ) ( beware: all your original files will be replaced with optimized files )
If you want to exlucde some input files in DatabaseRoot, just add theirs names into ExcludedFiles



--]]


local Root = "."
if arg and arg[0] then
	local s, e = string.find( arg[0], "Client" )
	if e then
		Root = string.sub( arg[0], 1, e )
	end
end
Root = string.gsub( Root, '\\', '/' )
local DatabaseRoot = Root.."/Assets/StreamingAssets/Database"
local LuaRoot = Root.."/Assets/StreamingAssets/LuaRoot"
package.path = package.path..';'..DatabaseRoot..'/?.lua'..';'.. LuaRoot..'/?.lua'

local EnableDatasetOptimize = true
local EnableDefaultValueOptimize = true
local EnableLocalization = true -- set to false to disable localization process

local Database = {}
local CSV --= require "std.csv"
local DefaultNumberSerializedFormat = "%.14g"
local NumberSerializedFormat = DefaultNumberSerializedFormat
local DatabaseLocaleTextName = "_LocaleText"
local StringBankOutput = DatabaseRoot.."/"..DatabaseLocaleTextName..".lua"
local StringBankCSVOutput = DatabaseRoot.."/"..DatabaseLocaleTextName..".csv"
local MaxStringBankRedundancy = 100
local MaxStringBankBinSize = 524288
local LocaleTextLeadingTag = '@'
local MaxLocalVariableNum = 190 -- lparser.c #define MAXVARS 200
local RefTableName = "__rt"
local DefaultValueTableName = "__default_values"
local PrintTableRefCount = false
local UnknownName = "___noname___"

local floor = math.floor
local fmod = math.fmod

local ExcludedFiles = {
	--Add file name to exclude from build
	_LocaleText = true,
}

local UniquifyTables = {} -- hash -> table
local UniquifyTablesIds = {} -- id -> hash
local UniquifyTablesInvIds = {} -- table -> id
local UniquifyTablesRefCounter = {} -- table -> refcount

local function HashString( v )
	local val = 0
	local fmod = fmod
	local gmatch = string.gmatch
	local byte = string.byte
	local MaxStringBankBinSize = MaxStringBankBinSize
	local c
	for _c in gmatch( v, "." ) do
		c = byte( _c )
		val = val + c * 193951
		val = fmod( val, MaxStringBankBinSize )
		val = val * 399283
		val = fmod( val, MaxStringBankBinSize )
	end
	return val
end

local function AddStringToBank( stringBank, str )
	local meta = getmetatable( stringBank )
	local reversed = nil
	local counter = nil
	if not meta then
		meta = {
			__counter = { used = {} }, -- mark used hash value
			__reversed = {} -- string -> hash reverse lookup
		}
		reversed = meta.__reversed
		counter = meta.__counter
		setmetatable( stringBank, meta )
		local remove = {}
		-- lazy initialize reverse lut
		for h, s in pairs( stringBank ) do
			local _h = reversed[ s ]
			assert( _h == nil )
			reversed[ s ] = h
		end
	end
	reversed = reversed or meta.__reversed
	counter = counter or meta.__counter
	local hash = reversed[ str ]
	if hash then
		counter.used[ hash ] = true
		return hash
	end
	hash = HashString( str )
	local _v = stringBank[ hash ]
	while _v do
		hash = hash + 1
		hash = fmod( hash, MaxStringBankBinSize )
		_v = stringBank[ hash ]
	end
	assert( not reversed[ str ] )
	stringBank[ hash ] = str
	reversed[ str ] = hash
	counter.used[ hash ] = true
	return hash
end

local function OrderedForeach( _table, _func )
	if type( _table ) == "table" then
		local kv = {}
		for k, v in pairs( _table ) do
			kv[ #kv + 1 ] = { k, v }
		end
		table.sort( kv,
			function( _l, _r )
				local l = _l[ 1 ]
				local r = _r[ 1 ]
				local lt = type( l )
				local rt = type( r )
				if lt == rt and lt ~= "table" then
					return l < r
				else
					return tostring( l ) < tostring( r )
				end
			end
		)
		for _, _v in ipairs( kv ) do
			local k = _v[ 1 ]
			local v = _v[ 2 ]
			_func( k, v )
		end
	end
end

local function OrderedForeachByValue( _table, _func )
	if type( _table ) == "table" then
		local kv = {}
		for k, v in pairs( _table ) do
			kv[ #kv + 1 ] = { k, v }
		end
		table.sort( kv,
			function( _l, _r )
				local l = _l[ 2 ]
				local r = _r[ 2 ]
				local lt = type( l )
				local rt = type( r )
				if lt == rt and lt ~= "table"then
					return l < r
				else
					return tostring( l ) < tostring( r )
				end
			end
		)
		for _, _v in ipairs( kv ) do
			local k = _v[ 1 ]
			local v = _v[ 2 ]
			_func( k, v )
		end
	end
end

local function EncodeEscapeString( s )
	local buf = {}
	buf[#buf + 1] = "\""
	string.gsub( s, ".",
		function ( c )
			if c == '\n' then
				buf[#buf + 1] = "\\n"
			elseif c == '\t' then
				buf[#buf + 1] = "\\t"
			elseif c == '\r' then
				buf[#buf + 1] = "\\r"
			elseif c == '\a' then
				buf[#buf + 1] = "\\a"
			elseif c == '\b' then
				buf[#buf + 1] = "\\b"
			elseif c == '\\' then
				buf[#buf + 1] = "\\\\"
			elseif c == '\"' then
				buf[#buf + 1] = "\\\""
			elseif c == '\'' then
				buf[#buf + 1] = "\\\'"
			elseif c == '\v' then
				buf[#buf + 1] = "\\\v"
			elseif c == '\f' then
				buf[#buf + 1] = "\\\f"
			else
				buf[#buf + 1] = c
			end
		end
	)
	buf[#buf + 1] = "\""
	return table.concat( buf, "" )
end

local function StringBuilder()
	local sb = {}
	local f = function( str )
		if str then
			sb[ #sb + 1 ] = str
		end
		return f, sb
	end
	return f
end

local function CreateFileWriter( fileName, mode )
	local file = nil
	local indent = 0
	if mode and fileName then
		local _file, err = io.open( fileName )
		if _file ~= nil then
			--print( "remove file "..fileName )
			os.remove( fileName )
		end
		file = io.open( fileName, mode )
	end
	local ret = nil
	if file then
		ret = {
			write = function( ... )
				if indent > 0 then
					for i = 0, indent - 1 do
						file:write( "\t" )
					end
				end
				return file:write( ... )
			end,
			close = function( ... )
				return file:close()
			end
		}
	else
		ret = {
			write = function( ... )
				for i = 0, indent - 1 do
					io.write( "\t" )
				end
				return io.write( ... )
			end,
			close = function( ... )
			end
		}
	end
	ret.indent = function( count )
		count = count or 1
		indent = indent + count or 1
	end
	ret.outdent = function( count )
		count = count or 1
		if indent >= count then
			indent = indent - count
		end
	end
	return ret
end

local function SetNumberSerializedFormat( f )
	NumberSerializedFormat = f or DefaultNumberSerializedFormat
	if NumberSerializedFormat == "" then
		NumberSerializedFormat = DefaultNumberSerializedFormat
	end
	print( "set NumberSerializedFormat: ".. NumberSerializedFormat )
end

local DefaultVisitor = {
	recursive = true,
	iVisit = function( i, v, curPath )
		print( string.format( "%s[%d] = %s", curPath, i, tostring( v ) ) )
		return true
	end,
	nVisit = function( n, v, curPath )
		print( string.format( "%s[%g] = %s", curPath, n, tostring( v ) ) )
		return true
	end,
	sVisit = function( s, v, curPath )
		local _v = tostring( v )
		print( #curPath > 0 and curPath.."."..s.." = ".._v or s.." = ".._v )
		return true
	end,
	xVisit = function( k, v, curPath )
		local sk = tostring( k )
		local sv = tostring( v )
		print( #curPath > 0 and curPath.."."..sk.." = "..sv or sk.." = "..sv )
		return true
	end
}

local function WalkDataset( t, visitor, parent )
	if not parent then
		parent = ""
	end
	-- all integer key
	local continue = true
	if visitor.iVisit then
		for i, v in ipairs( t ) do
			local _t = type( v )
			if _t == "table" and visitor.recursive then
				continue = WalkDataset( v, visitor, string.format( "%s[%g]", parent, i ) )
			elseif _t == "string" or _t == "number" then
				continue = visitor.iVisit( i, v, parent )
			else
				-- not support value type
				if visitor.xVisit then
					continue = visitor.xVisit( i, v, parent )
				end
			end
			if not continue then
				return continue
			end
		end
	end

	local len = #t
	local keys = {}
	local idict = {}
	for k, v in pairs( t ) do
		local _t = type( k )
		if _t == "number" then
			local intKey = k == math.floor( k );
			if k > len or k <= 0 or not intKey then
				idict[k] = v
			end
		elseif _t == "string" then
			keys[#keys + 1] = k
		else
			--table, function, ...
			--not support data type for key
			if visitor.xVisit then
				continue = visitor.xVisit( k, v, parent )
			end
		end
		if not continue then
			return continue
		end
	end
	-- for all number keys those are not in array part
	-- key must be number
	for k, v in pairs( idict ) do
		local intKey = k == math.floor( k );
		local _t = type( v )
		if _t ~= "table" then
			if _t == "number" or _t == "string" then
				if intKey then
					if visitor.iVisit then
						continue = visitor.iVisit( k, v, parent )
					end
				else
					if visitor.nVisit then
						continue = visitor.nVisit( k, v, parent )
					end
				end
			else
				-- not support value data type
				if visitor.xVisit then
					continue = visitor.xVisit( k, v, parent )
				end
			end
		elseif visitor.recursive then
			if intKey then
				continue = WalkDataset( v, visitor, string.format( "%s[%d]", parent, k ) )
			else
				continue = WalkDataset( v, visitor, string.format( "%s[%g]", parent, k ) )
			end
		end
		if not continue then
			return continue
		end
	end
	-- sort all string keys
	table.sort( keys )
	-- for all none-table value
	local tableValue
	for k, v in pairs( keys ) do
		local value = t[v]
		local _t = type( value )
		if _t == "number" or _t == "string" then
			-- print all number or string value here
			if visitor.sVisit then
				continue = visitor.sVisit( v, value, parent )
			end
		elseif _t == "table" then
			-- for table value
			if not tableValue then
				tableValue = {}
			end
			tableValue[ k ] = v
		else
			if visitor.xVisit then
				continue = visitor.xVisit( v, value, parent )
			end
		end
		if not continue then
			return continue
		end
	end
	if visitor.recursive then
		-- for all table value
		if tableValue then
			for k, v in pairs( tableValue ) do
				local value = t[v]
				continue = WalkDataset( value, visitor, #parent > 0 and parent.."."..v or v )
				if not continue then
					return continue
				end
			end
		end
	end
	return continue
end

local function PrintDataset( t, parent )
	if not parent then
		parent = ""
	end
	local string_format = string.format
	-- all integer key
	for i, v in ipairs( t ) do
		local _t = type( v )
		if _t == "table" then
			PrintDataset( v, string_format( "%s[%g]", parent, i ) )
		elseif _t == "string" or _t == "number" then
			print( string.format( "%s[%d] = %s", parent, i, tostring( v ) ) )
		else
			-- not support value type
		end
	end
	local len = #t
	local keys = {}
	local idict = {}
	for k, v in pairs( t ) do
		local _t = type( k )
		if _t == "number" then
			if k > len or k <= 0 then
				idict[k] = v
			end
		elseif _t == "string" then
			keys[#keys + 1] = k
		else
			--table, function, ...
			--not support data type for key
		end
	end
	-- for all number keys those are not in array part
	-- key must be number
	for k, v in pairs( idict ) do
		local intKey = k == math.floor( k )
		local _t = type( v )
		if _t ~= "table" then
			if _t == "number" or _t == "string" then
				if intKey then
					print( string_format( "%s[%d] = %s", parent, k, tostring( v ) ) )
				else
					print( string_format( "%s[%g] = %s", parent, k, tostring( v ) ) )
				end
			else
				-- not support value data type
			end
		else
			if intKey then
				PrintDataset( v, string_format( "%s[%d]", parent, k ) )
			else
				PrintDataset( v, string_format( "%s[%g]", parent, k ) )
			end
		end
	end
	-- sort all string keys
	table.sort( keys )
	-- for all none-table value
	local tableValue
	for k, v in pairs( keys ) do
		local value = t[v]
		local _t = type( value )
		if _t ~= "table" then
			-- print all number or string value here
			local _value = tostring( value )
			print( #parent > 0 and parent.."."..v.." = ".._value or v.." = ".._value )
		else
			-- for table value
			if not tableValue then
				tableValue = {}
			end
			tableValue[ k ] = v
		end
	end
	-- for all table value
	if tableValue then
		for k, v in pairs( tableValue ) do
			local value = t[v]
			PrintDataset( value, #parent > 0 and parent.."."..v or v )
		end
	end
end

local function DeserializeTable( val )
	local loader = loadstring or load -- lua5.2 compat
	local chunk = loader( "return " .. val )
	local ok, ret = pcall( chunk )
	if not ok then
		ret = nil
		print( "DeserializeTable failed!"..val )
	end
	return ret
end

local function _SerializeTable( val, name, skipnewlines, campact, depth, tableRef )
	local valt = type( val )
    depth = depth or 0
	campact = campact or false
	local append = StringBuilder()
	local eqSign = " = "
	local tmp = ""
	local string_format = string.format
	if not campact then
		append( string.rep( "\t", depth ) )
		skipnewlines = skipnewlines or false
	else
		skipnewlines = true
		eqSign = "="
	end
    if name then
		local nt = type( name )
		if nt == "string" then
			if name ~= "" then
				if string.match( name,'^%d+' ) then
					append( "[\"" )
					append( name )
					append( "\"]" )
				else
					append( name )
				end
			else
				append( "[\"\"]" )
			end
			append( eqSign )
		elseif nt == "number" then
			append( string_format( "[%s]", tostring( name ) ) )
			append( eqSign )
		else
			tmp = tmp .. "\"[inserializeable datatype for key:" ..  nt .. "]\""
		end
	end
	local ending = not skipnewlines and "\n" or ""
	if tableRef then
		local refName = tableRef[ val ]
		if refName then
			valt = "ref"
			val = refName
		end
	end
    if valt == "table" then
        append( "{" ) append( ending )
		local array_part = {}
		local count = 0
        for k, v in ipairs( val ) do
			if type( val ) ~= "function" then
				array_part[k] = true
				if count > 0 then
					append( "," )
					append( ending )
				end
				append( _SerializeTable( v, nil, skipnewlines, campact, depth + 1, tableRef ) )
				count = count + 1
			end
        end
		local sortedK = {}
		for k, v in pairs( val ) do
			if type( v ) ~= "function" then
				if not array_part[k] then
					sortedK[#sortedK + 1] = k
				end
			end
		end
		table.sort( sortedK )
		for i, k in ipairs( sortedK ) do
			local v = val[k]
			if count > 0 then
				append( "," )
				append( ending )
			end
			append( _SerializeTable( v, k, skipnewlines, campact, depth + 1, tableRef ) )
			count = count + 1
        end
		if count >= 1 then
			append( ending )
		end
		if not campact then
			append( string.rep( "\t", depth ) )
		end
		append( "}" )
    elseif valt == "number" then
		if DefaultNumberSerializedFormat == NumberSerializedFormat or math.floor( val ) == val then
			append( tostring( val ) )
		else
			append( string_format( NumberSerializedFormat, val ) )
		end
    elseif valt == "string" then
        append( EncodeEscapeString( val ) )
    elseif valt == "boolean" then
        append( val and "true" or "false" )
	elseif valt == "ref" then
		append( val or "nil" )
    else
        tmp = tmp .. "\"[inserializeable datatype:" .. valt .. "]\""
    end
	local _, slist = append()
    return table.concat( slist, "" )
end

local function SerializeTable( val, skipnewlines, campact, tableRef, name )
	getmetatable( "" ).__lt = function( a, b ) return tostring( a ):lower() < tostring( b ):lower() end
	local ret = _SerializeTable( val, name, skipnewlines, campact, 0, tableRef )
	getmetatable( "" ).__lt = nil
	return ret
end

local function DumpStringBank( stringBank )
	print( 'dump database local string bank begin...' )
	for k, v in pairs( stringBank ) do
		print( string.format( "\t[%g] = %s", k, v ) )
	end
	print( 'dump database local string bank end.' )
end

local function SaveStringBankToLua( stringBank, tofile )
	if tofile then
		local fileName = StringBankOutput
		local _file, err = io.open( fileName )
		if _file ~= nil then
			_file:close()
			os.remove( fileName )
		end
		file = io.open( fileName, "w" )
		local fmt = string.format
		file:write( fmt( "local %s = {\n", DatabaseLocaleTextName ) )
		for k, v in pairs( stringBank ) do
			file:write( fmt( "\t[%g] = %s,\n", k, EncodeEscapeString( v ) ) )
		end
		file:write( "}\n" )
		file:write( fmt( "return %s\n--EOF", DatabaseLocaleTextName ) )
		file:close()
	else
		DumpStringBank( stringBank )
	end
end

local function SaveStringBankToCSV( stringBank, tofile )
	local _exists = {}
	for k, v in pairs( stringBank ) do
		assert( not _exists[v] )
		_exists[ v ] = k
	end
	local csv = CSV
	if tofile and csv then
		local fileName = StringBankCSVOutput
		local _file, err = io.open( fileName )
		if _file ~= nil then
			_file:close()
			os.remove( fileName )
		end
		local t = {}
		local count = 1
		for k, v in pairs( stringBank ) do
			t[count] = { k, v }
			count = count + 1
		end
		table.sort( t,
			function( a, b )
				return a[1] < b[1]
			end
		)
		csv.save( fileName, t, true )
	else
		SaveStringBankToLua( stringBank, tofile )
	end
end

local function LoadStringBankFromLua( info )
	local stringBank = {}
	local chunk = loadfile( StringBankOutput )
	if chunk then
		print( 'load string bank: '..StringBankOutput )
		local last = chunk()
		if last and type( last ) == "table" then
			for k, v in pairs( last ) do
				stringBank[ k ] = v
			end
		end
	end
	return stringBank
end

local function LoadStringBankFromCSV()
	local stringBank = {}
	local csv = CSV
	if csv then
		local fileName = StringBankCSVOutput
		local file, err = io.open( fileName )
		if file then
			print( "Load StringBank: " .. fileName )
			file:close()
			local b = csv.load( fileName, true )
			local allstr = {}
			for i = 1, #b do
				local key = b[ i ][ 1 ]
				local value = b[ i ][ 2 ]
				local oldHash = allstr[ value ]
				if not oldHash then
					stringBank[ key ] = value
					allstr[ value ] = key
				else
					print( string.format( "\"%s\" already exists in StringBank with hash %d", value, oldHash ) )
				end
			end
		end
	else
		return LoadStringBankFromLua()
	end
	return stringBank
end

local function TrimStringBank( stringBank )
	-- remove useless values
	local meta = getmetatable( stringBank )
	if meta then
		local counter = meta.__counter
		if counter then
			local used = counter.used
			if used then
				local count = 0
				for hash, str in pairs( stringBank ) do
					count = count + 1
				end
				local unused = {}
				for hash, str in pairs( stringBank ) do
					if not used[ hash ] then
						unused[#unused + 1] = hash
					end
				end
				if #unused > MaxStringBankRedundancy then
					for _, h in ipairs( unused ) do
						stringBank[ h ] = nil
					end
				end
			end
		end
	end
end

local function GetAllFileNamesAtPath( path )
	path, _ = path:gsub( "/", "\\" )
	local ret = {}
	for dir in io.popen( string.format( "dir \"%s\" /S/b", path ) ):lines() do
		local s, e, f = dir:find( ".+\\(.+)%.lua$" )
		if f then
			table.insert( ret, f )
		end
	end
	table.sort( ret )
	return ret
end

local function LoadDataset( name )
	if not Database then
		_G["Database"] = {}
		Database.loaded = {}
	end
	local loader = function( name )
		Database.loaded = Database.loaded or {}
		local r = Database.loaded[name]
		if r then
			return r
		end
		local pname = string.gsub( name, "%.", "/" )
		local split = function( s, p )
			local rt= {}
			string.gsub( s, '[^'..p..']+', function( w ) table.insert( rt, w ) end )
			return rt
		end

		local curName = pname..".lua"
		local fileName = DatabaseRoot.."/"..curName
		local checkFileName = function( path, name )
			path, _ = path:gsub( "/", "\\" )
			local _name = string.lower( name )
			for dir in io.popen( string.format( "dir \"%s\" /s/b", path ) ):lines() do
				local s, e, f = dir:find( ".+\\(.+%.lua)$" )
				if f then
					local _f = string.lower( f )
					if _name == _f then
						return name == f, f -- not match, real name
					end
				end
			end
		end

		local m, real = checkFileName( DatabaseRoot, curName )
		if not m and real then
			local msg = string.format( "filename must be matched by case! realname: \"%s\", you pass: \"%s\"", real, curName )
			print( msg )
			os.execute( "pause" )
		end

		local chunk = loadfile( fileName )
		if not chunk then
			fileName = LuaRoot.."/"..pname..".lua"
			chunk, err = loadfile( fileName )
			if err then
				print( "\n\n" )
				print( "----------------------------------" )
				print( "Load lua failed: "..fileName )
				print( "Error:" )
				print( "\t"..err )
				print( "----------------------------------" )
				print( "\n\n" )
			end
		end
		print( fileName )
		assert( chunk )
		if not chunk then
			os.execute( "pause" )
		end
		local rval = chunk()
		if rval.__name ~= nil then
			os.execute( "pause table's key must not be '__name' which is the reserved keyword." )
		end
		if rval.__sourcefile ~= nil then
			os.execute( "pause table's key must not be '__sourcefile' which is the reserved keyword." )
		end
		rval.__name = name
		rval.__sourcefile = fileName

		local namespace = Database
		local ns = split( pname, '/' )
		local xname = ns[#ns] -- last one
		if #ns > 1 then
			for i = 1, #ns - 1 do
				local n = ns[i];
				if namespace[n] == nil then
					namespace[n] = {}
				end
				namespace = namespace[n]
			end
		end
		namespace[xname] = rval
		print( "dataset: "..name.." has been loaded" )
		Database.loaded[name] = rval
		return rval
	end
	return loader( name )
end

local function CheckNotAscii( v )
	if v ~= nil and type( v ) == "string" then
		local byte = string.byte
		for _c in string.gmatch( v, "." ) do
			local c = byte( _c )
			if c < 0 or c > 127 then
				return true
			end
		end
	end
	return false
end

local function LocalizeRecord( id, record, genCode, StringBank )
	local localized_fields = nil
	local subTable = nil
	OrderedForeach(
		record,
		function( k, v )
			local vt = type( v )
			if vt == "string" then
				if CheckNotAscii( v ) then
					if #v > 0 and string.sub( v, 1, 1 ) == LocaleTextLeadingTag then
						print( string.format( "invalid leading character for localized text! key, value: %s, %s", k, v ) )
						os.execute( "pause" )
					end
					if not localized_fields then
						localized_fields = {}
					end
					-- build localized id string with tag
					local sid = AddStringToBank( StringBank, v )
					localized_fields[ k ] = string.format( "%s%g", LocaleTextLeadingTag, sid )
					if genCode then
						genCode[ #genCode + 1 ] = {
							id,
							sid,
							v
						}
					end
				end
			elseif vt == "table" then
				if not subTable then
					subTable = {}
				end
				subTable[ #subTable + 1 ] = v
			end
		end
	)
	local localized = false
	if localized_fields then
		-- override localized string with tag
		localized = true
		for k, v in pairs( localized_fields ) do
			record[ k ] = localized_fields[ k ]
		end
	end
	if subTable then
		for _, sub in ipairs( subTable ) do
			localized = LocalizeRecord( 0, sub, genCode, StringBank ) or localized
		end
	end
	return localized
end

local function GetValueTypeNameCS( value )
	local t = type( value )
	if t == "string" then
		return "string"
	elseif t == "number" then
		if value == math.floor( value ) then
			return "int"
		else
			return "float"
		end
	elseif t == "boolean" then
		return "bool"
	elseif t == "table" then
		return "table"
	else
		return "void"
	end
end

local function UniquifyTable( t )
	if t == nil or type( t ) ~= "table" then
		return nil
	end
	local hash = SerializeTable( t, true, true )
	local ref = UniquifyTables[ hash ]
	if ref then
		local refcount = UniquifyTablesRefCounter[ ref ] or 1
		UniquifyTablesRefCounter[ ref ] = refcount + 1
		return ref
	end

	local overwrites = nil
	for k, v in pairs( t ) do
		overwrites = overwrites or {}
		if type( v ) == "table" then
			overwrites[ k ] = UniquifyTable( v )
		end
	end
	if overwrites then
		for k, v in pairs( overwrites ) do
			t[ k ] = overwrites[ k ]
		end
	end
	local id = #UniquifyTablesIds + 1
	UniquifyTablesIds[ id ] = hash
	UniquifyTables[ hash ] = t
	UniquifyTablesInvIds[ t ] = id
	UniquifyTablesRefCounter[ t ] = 1
	return t
end

local function OptimizeDataset( dataset )
	local ids = {}
	local names = {}
	local idType = nil
	-- choose cs data type
	-- for all fields in a record
	local typeNameTable = {}
	for k, v in pairs( dataset ) do
		local _sk = tostring( k )
		if _sk ~= "__name" and _sk ~= "__sourcefile" then
			if not idType then
				idType = type( k )
			end
			if idType == type( k ) then
				ids[ #ids + 1 ] = k
			end
		end
	end
	if EnableDefaultValueOptimize then
		-- find bigest table to generate all fields
		local majorItem = 1
		local f = 0
		for k, v in pairs( dataset ) do
			if type( v ) == "table" then
				local num = 0
				for _, _ in pairs( v ) do
					num = num + 1
				end
				if num > f then
					f = num
					majorItem = k
				end
			end
		end
		local v = dataset[ majorItem ]
		if type( v ) == "table" then
			for name, value in pairs( v ) do
				local nt = type( name )
				if nt == "string" and name == "id" then
					print( "this table already has a field named 'id'" )
				end
				if nt == "string" then
					names[ #names + 1 ] = name
				end
			end
			table.sort( names, function( a, b ) return a:lower() < b:lower() end )
			for i, field in ipairs( names ) do
				-- for all record / row
				for r, t in ipairs( ids ) do
					local record = dataset[ t ]
					if record[ field ] ~= nil then
						local v = record[ field ]
						local curType = GetValueTypeNameCS( v )
						if not typeNameTable[ field ] then
							typeNameTable[ field ] = curType
						elseif typeNameTable[ field ] == "int" and curType == "float" then
							-- overwrite int to float
							typeNameTable[ field ] = curType
						elseif curType == "table" then
							-- overwrite to table
							typeNameTable[ field ] = curType
						end
					end
				end
				-- patching miss fields with default values
				local curType = typeNameTable[ field ]
				for r, t in ipairs( ids ) do
					local record = dataset[ t ]
					local v = record[ field ]
					if v == nil then
						local ft = typeNameTable[ field ]
						if ft == "string" then
							v = ""
						elseif ft == "number" or ft == "int" or ft == "float" then
							v = 0
						elseif ft == "table" then
							v = {}
						elseif ft == "bool" then
							v = false
						end
						record[ field ] = v
					end
				end
			end
		end
	end

	ids = {}
	idType = nil
	UniquifyTables = {}
	UniquifyTablesIds = {}
	UniquifyTablesInvIds = {}
	UniquifyTablesRefCounter = {}

	local isIntegerKey = true
	local overwrites = nil
	OrderedForeach(
		dataset,
		function( k, v )
			local _sk = tostring( k )
			if _sk ~= "__name" and _sk ~= "__sourcefile" then
				if not idType then
					idType = type( k )
				end
				-- check type
				if idType == type( k ) then
					ids[ #ids + 1 ] = k
					if idType == "number" then
						if isIntegerKey then
							isIntegerKey = k == floor( k )
						end
					end
				end
				if type( v ) == "table" then
					overwrites = overwrites or {}
					overwrites[ k ] = UniquifyTable( v )
				end
			end
		end
	)
	if overwrites then
		for k, v in pairs( overwrites ) do
			dataset[ k ] = overwrites[ k ]
		end
	end
	local returnVal = nil
	if EnableDefaultValueOptimize then
		local defaultValues = nil
		for i, field in ipairs( names ) do
			local curType = typeNameTable[ field ]
			-- for all record/row
			local defaultValueStat = {
			}
			for r, t in ipairs( ids ) do
				local record = dataset[ t ]
				local v = record[ field ]
				if v ~= nil then
					local vcount = defaultValueStat[ v ] or 0
					defaultValueStat[ v ] = vcount + 1
				else
					assert( "default value missing!" )
				end
			end
			-- find the mostest used as a default value
			local max = -1
			local defaultValue = nil
			local _defaultValue = "{}"
			OrderedForeachByValue(
				defaultValueStat,
				function( value, count )
					if count >= max then
						if count > max then
							max = count
							defaultValue = value
							_defaultValue = SerializeTable( defaultValue, true, true )
						else
							if curType == "table" then
								local _value = SerializeTable( value, true, true )
								if #_value > #_defaultValue then
									defaultValue = value
									_defaultValue = SerializeTable( defaultValue, true, true )
								end
							else
								if value < defaultValue then
									defaultValue = value
									_defaultValue = SerializeTable( defaultValue, true, true )
								end
							end
						end
					end
				end
			)
			if defaultValue ~= nil then
				defaultValues = defaultValues or {}
				defaultValues[ field ] = defaultValue
			end
		end
		returnVal = defaultValues
	end

	-- remove tables whose's ref is 1 and re-mapping id
	local newid = 1
	local newIds = {}
	local newInvIds = {}

	OrderedForeach(
		UniquifyTablesIds,
		function( id, hash )
			local table = UniquifyTables[ hash ]
			local refcount = UniquifyTablesRefCounter[ table ]
			if refcount == 1 then
				UniquifyTables[ hash ] = nil
			else
				newIds[ newid ] = hash
				newInvIds[ table ] = newid
				newid = newid + 1
			end
		end
	)

	UniquifyTablesIds = newIds
	UniquifyTablesInvIds = newInvIds
	return returnVal
end

local function ToUniqueTableRefName( id )
	if id <= MaxLocalVariableNum then
		return string.format( RefTableName.."_%d", id )
	else
		return string.format( RefTableName.."[%d]", id - MaxLocalVariableNum )
	end
end

local function SaveDatasetToFile( dataset, tofile, tableRef, name )
	if tofile then
		outFile = CreateFileWriter( dataset.__sourcefile, "w" )
	else
		outFile = CreateFileWriter()
	end
	local ptr2ref = nil
	if tableRef and tableRef.ptr2ref then
		ptr2ref = tableRef.ptr2ref
	end
	if tableRef and tableRef.name2value then
		local name2table = tableRef.name2value
		local tables = tableRef.tables
		local tableIds = tableRef.tableIds
		local ptr2ref = tableRef.ptr2ref
		local refcounter = tableRef.refcounter
		local maxLocalVariableNum = tableRef.maxLocalVariableNum or MaxLocalVariableNum
		local refTableName = tableRef.refTableName or "__rt"
		local tableNum = #tableIds
		for id, hash in ipairs( tableIds ) do
			local table = tables[ hash ]
			if table and id <= maxLocalVariableNum then
				local refname = ptr2ref[ table ]
				-- temp comment out top level ref
				ptr2ref[ table ] = nil
				local refcount = refcounter[ table ]
				outFile.write(
					string.format(
						"%slocal %s = %s\n",
						PrintTableRefCount and string.format( "--ref:%d\n", refcount ) or "",
						refname,
						SerializeTable( table, false, false, ptr2ref )
					)
				)
				ptr2ref[ table ] = refname
			else
				break
			end
		end
		if tableNum > maxLocalVariableNum then
			local maxCount = tableNum - maxLocalVariableNum
			outFile.write( string.format( "local %s = createtable and createtable( %d, 0 ) or {}\n", refTableName, maxCount ) )
			for id = maxLocalVariableNum + 1, tableNum do
				local offset = id - maxLocalVariableNum
				local hash = tableIds[ id ]
				local table = tables[ hash ]
				local refname = ptr2ref[ table ]
				-- temp comment out top level ref
				ptr2ref[ table ] = nil
				local refcount = refcounter[ table ]
				outFile.write(
					string.format(
						"%s%s[%d] = %s\n",
						PrintTableRefCount and string.format( "-- %s, ref:%d\n", refname, refcount ) or "",
						refTableName, offset,
						SerializeTable( table, false, false, ptr2ref )
					)
				)
				ptr2ref[ table ] = refname
			end
		end
	end
	local datasetName = dataset.__name or name
	if not datasetName then
		datasetName = UnknownName
		dataset.__name = datasetName
	end
	outFile.write( string.format( "local %s = \n", datasetName ) )

	-- remove none table value
	local removed = nil
	for k, v in pairs( dataset ) do
		if type( v ) ~= "table" then
			removed = removed or {}
			removed[ #removed + 1 ] = k
		end
	end
	if removed then
		for _, k in ipairs( removed ) do
			dataset[ k ] = nil
		end
	end

	outFile.write( SerializeTable( dataset, false, false, ptr2ref ) )
	outFile.write( "\n" )
	if tableRef and tableRef.postOutput then
		tableRef.postOutput( outFile )
	end
	outFile.write( string.format( "\nreturn %s\n", datasetName ) )
	outFile.close()
end

local function ExportOptimizedDataset( t, StringBank )
	local datasetName = t.__name
	if not datasetName then
		datasetName = UnknownName
		t.__name = datasetName
	end
	local localized = false
	local genCode = false
    if EnableLocalization then
        OrderedForeach(
            t,
            function( id, _record )
                if type( _record ) == "table" then
                    localized = LocalizeRecord( id, _record, genCode, StringBank ) or localized
                end
            end
        )
    end
	local tableRef = nil
	local defaultValues = nil
	if EnableDatasetOptimize then
		defaultValues = OptimizeDataset( t )
		if defaultValues then
			local removeDefaultValues = function( record )
				local removes = nil
				local adds = nil
				for field, defaultVal in pairs( defaultValues ) do
					local value = record[ field ]
					local hasValue = true
					if value == nil then
						assert( false, "OptimizeDataset should patch all missing fields!" )
						hasValue = false
					end
					if value == defaultVal and hasValue then
						removes = removes or {}
						removes[ #removes + 1 ] = field
					else
						adds = adds or {}
						adds[ field ] = value
					end
				end
				-- remove fields with default value
				if removes then
					for _, f in ipairs( removes ) do
						record[ f ] = nil
					end
				end
				-- patch fields with none-default value
				if adds then
					for f, v in pairs( adds ) do
						record[ f ] = v
					end
				end
			end
			local removed = {}
			for _, record in pairs( t ) do
				if type( record ) == "table" then
					if not removed[ record ] then
						removeDefaultValues( record )
						removed[ record ] = true
					end
				end
			end
		end
		local reftables = nil
		local ptr2ref = nil
		-- create ref table: table -> refname
		for _, hash in pairs( UniquifyTablesIds ) do
			local t = UniquifyTables[ hash ]
			if t then
				local refName = ToUniqueTableRefName( UniquifyTablesInvIds[ t ] )
				reftables = reftables or {}
				ptr2ref = ptr2ref or {}
				reftables[ refName ] = t
				ptr2ref[ t ] = refName
			end
		end
		tableRef = {
			name2value = reftables,
			tables = UniquifyTables, -- hash -> table
			tableIds = UniquifyTablesIds, -- id -> hash
			ptr2ref = ptr2ref, -- table -> refname
			refcounter = UniquifyTablesRefCounter, -- table -> refcount
			maxLocalVariableNum = MaxLocalVariableNum,
			refTableName = RefTableName,
			postOutput = function( outFile )
				if defaultValues then
					outFile.write(
						string.format(
							"local %s = %s\n",
							DefaultValueTableName,
							SerializeTable( defaultValues, false, false, ptr2ref )
						)
					)
					outFile.write( "do\n" )
					outFile.write( string.format( "\tlocal base = { __index = %s, __newindex = function() error( \"Attempt to modify read-only table\" ) end }\n", DefaultValueTableName ) )
					outFile.write( string.format( "\tfor k, v in pairs( %s ) do\n", datasetName ) )
					outFile.write( "\t\tsetmetatable( v, base )\n" )
					outFile.write( "\tend\n" )
					outFile.write( "\tbase.__metatable = false\n" )
					outFile.write( "end\n" )
				end
			end
		}
	end
	return t, tableRef, localized
end

--tofile: not output to file, just for debug
--newStringBank: if false, exporter will use existing string hash for increamental building
local function ExportDatabaseLocalText( tofile, newStringBank )
	local StringBank = nil
	if newStringBank then
		StringBank = {}
	else
		StringBank = LoadStringBankFromCSV()
	end
	StringBank = StringBank or {}
	local localized_dirty = false
	local files = GetAllFileNamesAtPath( DatabaseRoot )
	for _, v in ipairs( files ) do
		if not ExcludedFiles[ v ] then
			print( "LoadDataset :"..v )
			LoadDataset( v )
			local t = Database[ v ]
			local localized = false
			if t then
				local _t, tableRef, localized = ExportOptimizedDataset( t, StringBank )
				assert( _t == t )
				localized_dirty = localized_dirty or localized
				SaveDatasetToFile( Database[ v ], tofile, tableRef )
			end
		end
	end
	TrimStringBank( StringBank )
	if localized_dirty then
		SaveStringBankToCSV( StringBank, tofile )
	else
		print( "\nDatabase LocaleText is up to date.\n" )
	end
	print( "Database Exporting LocaleText done." )
end

--[[
local test = {
	{
		1,
		2,
		3,
		a = "123",
		b = "123"
	},
	{
		1,
		2,
		3,
		a = "123",
		b = "123"
	},
	{
		1,
		2,
		5,
		a = "123",
		b = "123"
	},
	[9] = {
		1,
		2,
		5,
		a = "123",
		b = "123"
	},
	[100] = {
		1,
		2,
		3,
		a = "tttt",
		b = "123"
	},
	[11] = {
		1,
		2,
		3,
		a = "123",
		b = "123",
		c = { {1}, {1}, {2}, {2} },
		d = { { a = 1, 1 }, { a = 2, 2 } },
		e = { { a = 1, 1 }, { a = 2, 2 } },
	}
}

EnableDefaultValueOptimize = false
local _localizedText = {}
local _src = SerializeTable( test )
local _clone = DeserializeTable( _src )
print( _src )
local t, tableRef = ExportOptimizedDataset( test, _localizedText )
assert( t == test )
--print( SerializeTable( t ) )
SaveDatasetToFile( t, false, tableRef, "test" )
local _dst = SerializeTable( t )
print( _dst )
assert( _src == _dst )

EnableDefaultValueOptimize = true
_localizedText = {}
t, tableRef = ExportOptimizedDataset( _clone, _localizedText )
assert( t == _clone )
--_clone.__name = "__cloned_test"
SaveDatasetToFile( _clone, false, tableRef )
local _dst = SerializeTable( _clone )
print( _dst )
print( _src ~= _dst )
--]]

--ExportDatabaseLocalText( false )

