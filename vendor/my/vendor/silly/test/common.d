module common;

shared static this() {
	import core.runtime : dmd_coverDestPath, dmd_coverSetMerge;
	import std.path : dirName, buildNormalizedPath;

	dmd_coverSetMerge = true;
	dmd_coverDestPath = __FILE_FULL_PATH__.dirName.buildNormalizedPath(".coverage");
}