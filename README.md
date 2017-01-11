#LuaTableOptimizer
===================================================================================
Simple readonly lua table optimizer 
-----------------------------------------------------------------------------------
    Lua'table 通常被用来存储游戏大量的配置数据，如果配置中有很多冗余重复的数据，那么这个
配置表将占用较多的内存，并且影响加载速度。

功能:
1.获取字段中使用最多次数的值作为默认值，并且删除默认值字段
2.使用了非ASCII字符集字符的字段被视为需要做多语言化处理并提取替换成特殊标识符
3.唯一化所有的子table，并且指向同一个引用，以节约内存

   Lua'table commonly use to store configuration data for games. it takes a lot of memory
if it contains many fields with same value. this optimization could improve memory usage
and loading speed.

features:
1.remove default value fields ( store them into metatable )
2.auto localization
3.reuse all table values to save memory


require:
the key of the root table must be all string or number as id

```lua
{
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
	[11] = {
		1,
		2,
		3,
		a = "123",
		b = "123",
		c = {
			{
				1
			},
			{
				1
			},
			{
				2
			},
			{
				2
			}
		},
		d = {
			{
				1,
				a = 1
			},
			{
				2,
				a = 2
			}
		},
		e = {
			{
				1,
				a = 1
			},
			{
				2,
				a = 2
			}
		}
	},
	[100] = {
		1,
		2,
		3,
		a = "tttt",
		b = "123"
	}
}
```
```lua
local __rt_1 = {
}
local __rt_2 = {
	1,
	2,
	3
}
local __rt_3 = {
	1,
	2,
	5
}
local __rt_4 = {
	{
		1,
		a = 1
	},
	{
		2,
		a = 2
	}
}
local __rt_5 = {
	1
}
local __rt_6 = {
	2
}
local test = 
{
	__rt_2,
	__rt_2,
	__rt_3,
	[9] = __rt_3,
	[11] = {
		1,
		2,
		3,
		c = {
			__rt_5,
			__rt_5,
			__rt_6,
			__rt_6
		},
		d = __rt_4,
		e = __rt_4
	},
	[100] = {
		1,
		2,
		3,
		a = "tttt"
	}
}
local __default_values = {
	a = "123",
	b = "123",
	c = __rt_1,
	d = __rt_1,
	e = __rt_1
}
do
	local base = { __index = __default_values, __newindex = function() error( "Attempt to modify read-only table" ) end }
	for k, v in pairs( nil ) do
		setmetatable( v, base )
	end
	base.__metatable = false
end

return test
```

