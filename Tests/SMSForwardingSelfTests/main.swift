import Foundation

enum SelfTestFailure: Error {
    case failed(String)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw SelfTestFailure.failed(message) }
}

// Reference values computed independently in Python (hmac + hashlib + base64)
// for the same secret/timestamp inputs, so this checks the Swift
// implementation against a second, independent implementation of the
// documented algorithms rather than against itself.
do {
    let feishuSign = SMSForwardingSigning.feishuSign(
        secret: "test_secret_123",
        timestampSeconds: 1_700_000_000
    )
    try expect(
        feishuSign == "ADXLocYmfIVvbO1q8epZkDElPLHsHxmj27uaQhfuRhE=",
        "Feishu sign did not match the independently-computed reference vector"
    )

    let dingTalkSign = SMSForwardingSigning.dingTalkSign(
        secret: "test_secret_123",
        timestampMilliseconds: 1_700_000_000_000
    )
    try expect(
        dingTalkSign == "4E76yXqQpW1fliVff/re+A7gBQu9SFSO72yXPSls3dA=",
        "DingTalk sign did not match the independently-computed reference vector"
    )

    // Feishu and DingTalk deliberately swap which side is the HMAC key vs.
    // message; guard against ever accidentally unifying the two call sites.
    try expect(
        feishuSign != dingTalkSign,
        "Feishu and DingTalk signs collided unexpectedly for matching inputs"
    )

    let encoded = SMSForwardingSigning.urlEncodedQueryValue("a+b/c=d e")
    try expect(
        encoded == "a%2Bb%2Fc%3Dd%20e",
        "urlEncodedQueryValue did not percent-encode reserved query characters"
    )

    // Feishu and DingTalk reply HTTP 200 either way; the body decides.
    func rejection(_ json: String, _ keys: [String]) -> String? {
        SMSForwardingSigning.webhookRejection(in: Data(json.utf8), resultCodeKeys: keys)
    }
    try expect(
        rejection(#"{"errcode":0,"errmsg":"ok"}"#, ["errcode"]) == nil &&
            rejection(
                #"{"StatusCode":0,"StatusMessage":"success","code":0,"data":{},"msg":"success"}"#,
                ["code", "StatusCode"]
            ) == nil &&
            rejection("", ["errcode"]) == nil &&
            rejection("not json", ["errcode"]) == nil &&
            rejection(#"{"errcode":310000,"errmsg":"sign not match"}"#, []) == nil,
        "an accepted webhook reply was reported as a rejection"
    )
    try expect(
        rejection(#"{"errcode":310000,"errmsg":"keywords not in content"}"#, ["errcode"]) ==
            "310000 keywords not in content" &&
            rejection(#"{"code":19021,"msg":"sign match fail"}"#, ["code", "StatusCode"]) ==
            "19021 sign match fail" &&
            rejection(#"{"errcode":"130101"}"#, ["errcode"]) == "130101",
        "a rejected webhook reply was reported as delivered"
    )

    print("All SMSForwardingSelfTests passed.")
} catch {
    print("SMSForwardingSelfTests FAILED: \(error)")
    exit(1)
}
