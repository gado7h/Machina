local ImageCatalogUtils = {}

function ImageCatalogUtils.deepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, child in pairs(value) do
		out[key] = ImageCatalogUtils.deepCopy(child)
	end
	return out
end

function ImageCatalogUtils.sectorsToDiskBytes(sectors)
	local maxLba = -1
	for lba in pairs(sectors or {}) do
		maxLba = math.max(maxLba, tonumber(lba) or -1)
	end

	local bytes = {}
	for lba = 0, maxLba do
		local sector = sectors[lba] or {}
		for byteIndex = 1, 512 do
			bytes[#bytes + 1] = (tonumber(sector[byteIndex]) or 0) % 256
		end
	end
	return bytes
end

return ImageCatalogUtils
