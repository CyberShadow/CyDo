module cydo.workflow.questions.router;

import cydo.foundation.system.known_messages : KnownSystemMessageKind,
	questionFromTaskSubject, wrapKnownSystemMessage;

package(cydo):

string makeQuestionMessage(string systemKeyword, int askerTid, int qid,
	string renderedBody)
{
	return wrapKnownSystemMessage(systemKeyword,
		KnownSystemMessageKind.questionFromTask, renderedBody,
		questionFromTaskSubject(askerTid, qid));
}
