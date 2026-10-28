# Marks an error as leaving upstream work in an UNKNOWN state.
#
# The question an admission slot has to answer is not "did the call fail" but
# "did we learn the outcome". An HTTP 400 arrived, so the provider is done. A
# read timeout means we stopped waiting: the GPU may still be generating, and
# the remote MCP tool may still be running. Releasing the slot then admits
# replacement work on top of work that never stopped.
#
# A wrapper error that hides a post-write transport failure includes this
# module, so AnonymousUsagePolicy can tell the two apart without unwrapping
# anybody's exception chain.
module UpstreamUncertain
end
