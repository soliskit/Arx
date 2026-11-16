// Controlled browser failures against fixture data only. No native account access.
import assert from "node:assert/strict";

export async function checkBrowserOutcomes({ evaluate, until, screenshot }) {
  await evaluate(`window.outcomeFixture = { originalFetch: window.fetch.bind(window), mode: "normal", commands: [] };
    window.fetch = async (path, options) => {
      const fixture = window.outcomeFixture;
      const body = options?.body ? JSON.parse(options.body) : null;
      const reply = (status, error) => new Response(JSON.stringify({ error }), { status });
      if (path === "/api/mutate") {
        fixture.commands.push(body);
        if (fixture.mode === "lost") throw Error("Fixture dropped response");
        if (["active-denial", "unknown-denial", "html-session", "invalid-session"].includes(fixture.mode)) return reply(403, "Fixture item unavailable");
        if (fixture.mode === "html-denial") return new Response("<html>Denied</html>", {status: 403});
        if (fixture.mode === "refused-400") return reply(400, "Fixture bad fields");
        if (fixture.mode === "refused-429") return reply(429, "Fixture throttled");
        if (["off-page", "reload-failure", "failed-switch"].includes(fixture.mode)) {
          return new Response(JSON.stringify({ reminder: { id: "off-page-fixture", listID: body.listID, fields: body.fields } }));
        }
      }
      if (path === "/api/session") {
        if (["unknown-denial", "html-denial"].includes(fixture.mode)) return reply(503, "Fixture session check unavailable");
        if (fixture.mode === "html-session") return new Response("<html>Upstream login</html>");
        if (fixture.mode === "invalid-session") return reply(200, "Upstream unavailable");
      }
      if (path === "/api/read" && (fixture.mode === "reload-failure" || (fixture.mode === "failed-switch" && body.listID === fixture.target))) return reply(503, "Fixture read unavailable");
      return fixture.originalFetch(path, options);
    };`);
  const mode = (value) =>
    evaluate(`window.outcomeFixture.mode=${JSON.stringify(value)}`);
  const status = () =>
    evaluate('document.getElementById("status").textContent');
  const submit = async () => {
    await evaluate('document.getElementById("new").click()');
    await until('!busy && !document.getElementById("editor").hidden');
    await evaluate(
      'document.getElementById("title").value="Outcome fixture";document.getElementById("edit-form").requestSubmit()',
    );
    await until("!busy");
  };
  try {
    const initial = await evaluate(
      '({id:listID, heading:document.getElementById("list-title").textContent})',
    );
    await mode("failed-switch");
    await evaluate(
      'window.outcomeFixture.target=lists.find(list=>list.id!==listID).id;[...document.getElementById("lists").children].find(button=>button.textContent===lists.find(list=>list.id===window.outcomeFixture.target).title).click()',
    );
    await until("!busy");
    assert.deepEqual(
      await evaluate(
        '({id:listID, heading:document.getElementById("list-title").textContent})',
      ),
      initial,
    );
    await submit();
    assert.equal(
      await evaluate("window.outcomeFixture.commands.at(-1).listID"),
      initial.id,
    );
    assert.match(await status(), /not on the page shown/);
    await screenshot("06a-failed-switch-safe-target");

    await mode("lost");
    await submit();
    assert.match(await status(), /may or may not have been saved/);
    await screenshot("06b-lost-write-warning");
    await mode("normal");
    await evaluate('document.getElementById("refresh").click()');
    await until("!busy");
    assert.match(await status(), /did not confirm.*Check Reminders/);
    const unresolved = await evaluate("JSON.stringify(uncertainWrites)");
    const retainsUnresolved = async (next) => {
      await mode(next);
      await submit();
      assert.equal(
        await evaluate("JSON.stringify(uncertainWrites)"),
        unresolved,
      );
      await mode("normal");
      await evaluate('document.getElementById("refresh").click()');
      await until("!busy");
      assert.equal(
        await evaluate("JSON.stringify(uncertainWrites)"),
        unresolved,
      );
      assert.match(await status(), /Unresolved writes:.*did not confirm/);
    };
    await retainsUnresolved("off-page");
    await retainsUnresolved("refused-400");
    await retainsUnresolved("refused-429");
    await mode("lost");
    await submit();
    assert.equal(await evaluate("uncertainWrites.length"), 2);

    await mode("reload-failure");
    await submit();
    assert.match(
      await status(),
      /Change saved, but the list could not be reloaded/,
    );

    await mode("off-page");
    await submit();
    assert.match(await status(), /not on the page shown/);
    await screenshot("06c-off-page-saved");

    await mode("active-denial");
    await submit();
    assert.equal(
      await evaluate('document.getElementById("pairing").hidden'),
      true,
    );
    assert.match(await status(), /no longer available to this client/);

    const clearsUnverified = async (failure) => {
      await mode(failure);
      await submit();
      assert.equal(
        await evaluate('document.getElementById("workspace").hidden'),
        true,
      );
      assert.equal(
        await evaluate('document.getElementById("reminders").textContent'),
        "",
      );
      assert.match(await status(), /Access could not be verified/);
      await screenshot(`06d-${failure}-cleared`);
      await mode("normal");
      await evaluate("run(refresh)");
      await until('!busy && !document.getElementById("workspace").hidden');
      await evaluate(
        '[...document.getElementById("lists").children].find(button=>button.textContent==="Inbox").click()',
      );
      await until('!busy && rows.some(row=>row.id==="book")');
    };
    await clearsUnverified("unknown-denial");
    await clearsUnverified("html-session");
    await clearsUnverified("invalid-session");
    await clearsUnverified("html-denial");
  } finally {
    await evaluate(
      "window.fetch=window.outcomeFixture.originalFetch;delete window.outcomeFixture",
    );
  }
  await evaluate("run(refresh)");
  await until('!busy && !document.getElementById("workspace").hidden');
  await evaluate(
    '[...document.getElementById("lists").children].find(button=>button.textContent==="Inbox").click()',
  );
  await until('!busy && rows.some(row=>row.id==="book")');
}
