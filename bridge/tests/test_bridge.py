import contextlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import MagicMock, patch
import uuid

SPEC = importlib.util.spec_from_file_location('bridge', Path(__file__).parents[1] / 'sidea_bridge.py')
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)


def account(name='Personal', **extra):
    return dict(id=str(uuid.uuid4()), name=name, email=name.lower()+'@example.com', ready=True, allowAuto=True, **extra)


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        # Never touch the real ~/.claude refresh lock.
        env=patch.dict(os.environ,{'CLAUDE_CONFIG_DIR':str(self.root/'claude-home')}); env.start(); self.addCleanup(env.stop)
    def tearDown(self):
        self.temp.cleanup()
    def test_corrupt_config_is_not_treated_as_empty(self):
        path = self.root / 'config.json'; path.write_text('{broken')
        with self.assertRaises(json.JSONDecodeError): bridge.read_json(path, {})
    def test_rejects_path_traversal(self):
        with self.assertRaises(ValueError): bridge.account_by_id({'accounts': []}, '../../secret')
        with self.assertRaises(ValueError): bridge.prepare_profile(self.root, '../../secret')
    def test_strips_all_credential_and_provider_overrides(self):
        with patch.dict(os.environ, {'ANTHROPIC_API_KEY': 'secret', 'CLAUDE_CODE_OAUTH_TOKEN': 'secret', 'CLAUDECODE':'1', 'CLAUDE_CODE_USE_BEDROCK':'1', 'AWS_PROFILE':'prod', 'CLAUDE_CONFIG_DIR':'wrong'}):
            env = bridge.clean_environment(self.root)
        self.assertEqual(env['CLAUDE_CONFIG_DIR'], str(self.root))
        for key in ('ANTHROPIC_API_KEY', 'CLAUDE_CODE_OAUTH_TOKEN', 'CLAUDECODE', 'AWS_PROFILE', 'CLAUDE_CODE_USE_BEDROCK'):
            self.assertNotIn(key, env)
    def test_profile_keychain_service_matches_cli_naming(self):
        # Observed in the Keychain for this real profile path with Claude Code 2.1.292.
        root=Path('/Users/arne/Library/Application Support/SideA')
        self.assertEqual(bridge.profile_service(root,'cf1157b7-6e79-4726-949f-4f7a4b92706a'),'Claude Code-credentials-16898129')
    def vault_patches(self, home, vault, owners):
        return [patch.object(Path,'home',return_value=home),
                patch.object(bridge,'read_secret',side_effect=lambda s: json.loads(json.dumps(vault.get(s)))),
                patch.object(bridge,'token_email',side_effect=lambda root,blob: owners.get(((blob or {}).get('claudeAiOauth') or {}).get('accessToken'),''))]
    def setup_pair(self):
        home=self.root/'home'; home.mkdir()
        a,b=account('Alpha'),account('Beta')
        for item in (a,b): bridge.prepare_profile(self.root,item['id'])
        login=lambda token,expires=3600:{'claudeAiOauth':{'accessToken':token,'refreshToken':'r-'+token,'expiresAt':(time.time()+expires)*1000}}
        return home,a,b,login
    def selector(self):
        return (self.root/'runtime/claude-selector').read_text().strip()
    def test_use_points_new_commands_at_the_accounts_own_login(self):
        home,a,b,login=self.setup_pair()
        vault={bridge.GLOBAL_SERVICE:login('alpha'), bridge.profile_service(self.root,b['id']):login('beta')}
        config={'accounts':[a,b]}
        with contextlib.ExitStack() as stack:
            for item in self.vault_patches(home,vault,{'alpha':a['email'],'beta':b['email']}): stack.enter_context(item)
            self.assertEqual(bridge.global_account(config,self.root),a)
            bridge.activate(self.root,config,b)
            self.assertEqual(self.selector(),str(bridge.profile_dir(self.root,b['id'])))
            self.assertEqual(bridge.global_account(config,self.root),b)
            bridge.activate(self.root,config,a)
            self.assertEqual(self.selector(),'')
        self.assertFalse((home/'.claude.json').exists())
    def test_a_failed_identity_lookup_keeps_the_chosen_account(self):
        # Review: a profile lookup failing after token rotation reset the selection to the Mac login.
        home,a,b,login=self.setup_pair()
        vault={bridge.GLOBAL_SERVICE:login('alpha'), bridge.profile_service(self.root,b['id']):login('beta')}
        config={'accounts':[a,b]}
        with contextlib.ExitStack() as stack:
            for item in self.vault_patches(home,vault,{'alpha':a['email'],'beta':b['email']}): stack.enter_context(item)
            bridge.activate(self.root,config,b)
        vault[bridge.profile_service(self.root,b['id'])]=login('beta-rotated')
        with contextlib.ExitStack() as stack:
            for item in self.vault_patches(home,vault,{'alpha':a['email']}): stack.enter_context(item)
            self.assertEqual(bridge.repair_selection(self.root,config)['id'],b['id'])
        self.assertEqual(self.selector(),str(bridge.profile_dir(self.root,b['id'])))
    def test_selection_follows_the_mac_login_when_it_changes(self):
        # Alpha (the Mac login) is selected; then the Mac signs in as Beta, whose profile slot is a stale copy.
        home,a,b,login=self.setup_pair()
        vault={bridge.GLOBAL_SERVICE:login('alpha'), bridge.profile_service(self.root,b['id']):login('beta-old')}
        owners={'alpha':a['email'],'beta-old':b['email'],'beta-new':b['email']}
        config={'accounts':[a,b]}
        with contextlib.ExitStack() as stack:
            for item in self.vault_patches(home,vault,owners): stack.enter_context(item)
            bridge.activate(self.root,config,b)
            vault[bridge.GLOBAL_SERVICE]=login('beta-new')
            # Beta's login now lives in the Mac item, so the old profile selection must not be used.
            self.assertEqual(bridge.repair_selection(self.root,config),b)
            self.assertEqual(self.selector(),'')
    def test_slots_holding_another_accounts_login_are_refused_everywhere(self):
        home,a,b,login=self.setup_pair()
        vault={bridge.GLOBAL_SERVICE:login('alpha'), bridge.profile_service(self.root,b['id']):login('alpha-copy')}
        owners={'alpha':a['email'],'alpha-copy':a['email']}
        config={'accounts':[a,b]}
        with contextlib.ExitStack() as stack:
            for item in self.vault_patches(home,vault,owners): stack.enter_context(item)
            post=stack.enter_context(patch.object(bridge,'post_json'))
            run=stack.enter_context(patch.object(bridge.subprocess,'run'))
            for action in (lambda: bridge.activate(self.root,config,b), lambda: bridge.claude_usage(self.root,config,b),
                           lambda: bridge.prime(self.root,config,b)):
                with self.assertRaisesRegex(ValueError,'Sign in to Beta'): action()
            post.assert_not_called(); run.assert_not_called()
        self.assertFalse((self.root/'runtime/claude-selector').exists())
    def test_unverified_login_is_never_used_and_no_mac_login_means_profile_slots(self):
        # Review: an unknown owner (profile lookup failing) was accepted as the account's,
        # and with no Mac login an email-less account was sent to the empty default item.
        home,a,b,login=self.setup_pair()
        vault={bridge.profile_service(self.root,b['id']):login('mystery')}
        config={'accounts':[a,b]}
        with contextlib.ExitStack() as stack:
            for item in self.vault_patches(home,vault,{}): stack.enter_context(item)
            post=stack.enter_context(patch.object(bridge,'post_json'))
            for action in (lambda: bridge.activate(self.root,config,b), lambda: bridge.claude_usage(self.root,config,b)):
                with self.assertRaisesRegex(ValueError,"confirm"): action()
            post.assert_not_called()
            self.assertEqual(bridge.home_service(self.root,dict(b,email='')),bridge.profile_service(self.root,b['id']))
    def test_usage_reads_without_refreshing_or_writing_a_login(self):
        home,a,b,login=self.setup_pair()
        vault={bridge.GLOBAL_SERVICE:login('alpha'), bridge.profile_service(self.root,b['id']):login('beta',expires=-5000)}
        owners={'alpha':a['email'],'beta':b['email']}
        config={'accounts':[a,b]}
        # Shape of the live response: legacy per-model keys are null; model caps arrive as scoped limits.
        usage={'five_hour':{'utilization':40,'resets_at':'2026-10-06T20:00:00Z'},'seven_day':{'utilization':10,'resets_at':None},
               'seven_day_opus':None,'limits':[{'kind':'session','percent':40,'scope':None},
               {'kind':'weekly_scoped','percent':3,'resets_at':'2026-10-11T00:00:00Z','scope':{'model':{'id':None,'display_name':'Fable'},'surface':None}}]}
        with contextlib.ExitStack() as stack:
            for item in self.vault_patches(home,vault,owners): stack.enter_context(item)
            post=stack.enter_context(patch.object(bridge,'post_json',return_value=usage))
            writer=stack.enter_context(patch.object(bridge,'write_secret'))
            result=bridge.claude_usage(self.root,config,a)
            self.assertEqual([(w['id'],w['percent']) for w in result['windows']],[('five_hour',40.0),('seven_day',10.0),('model:fable',3.0)])
            # Reading never renews: an expired login reports idle, and renewal is a separate, locked step.
            with self.assertRaisesRegex(ValueError,'idle'): bridge.claude_usage(self.root,config,b)
            self.assertEqual(post.call_count,1)
            # Review: a 401 returned empty windows, wiping the last reading with no backoff.
            post.side_effect=bridge.urllib.error.HTTPError(bridge.USAGE_URL,401,'',{},None)
            with self.assertRaisesRegex(ValueError,'Sign in to Alpha'): bridge.claude_usage(self.root,config,a)
            writer.assert_not_called()
    def test_shell_switch_survives_path_aliases_and_upgrades_the_old_function(self):
        home=self.root/'home'; home.mkdir(); rc=home/'.zshrc'
        fake=self.root/'bin'; fake.mkdir(); (fake/'claude').write_text('#!/bin/sh\necho "${CLAUDE_SECURESTORAGE_CONFIG_DIR-unset}|$*"\n'); (fake/'claude').chmod(0o755)
        # The installer's alias points at a path, which skipped the old `claude` function.
        mine=f"alias claude={fake}/claude\n"
        # Review: a dotfiles-managed (symlinked) .zshrc was replaced by a plain file.
        dotfiles=self.root/'dotfiles'; dotfiles.mkdir()
        (dotfiles/'zshrc').write_text(mine+"\n"+bridge.SHELL_MARK+"\nfunction claude { command claude \"$@\"; }\n")
        rc.symlink_to(dotfiles/'zshrc')
        with patch.object(Path,'home',return_value=home):
            self.assertTrue(bridge.shell_installed(self.root))
            bridge.set_shell(self.root,True)
            self.assertTrue(rc.is_symlink())
            self.assertEqual(rc.read_text().count(bridge.SHELL_MARK),1)
            self.assertNotIn('function claude',rc.read_text())
            selector=self.root/'runtime/claude-selector'; selector.parent.mkdir(parents=True,exist_ok=True)
            run=lambda: subprocess.run(['zsh','-fc',f"source {rc}; (( ${{preexec_functions[(I)_side_a_select]}} )) || exit 3; _side_a_select; eval 'claude --version'"],
                                       capture_output=True,text=True).stdout.strip()
            selector.write_text('/profiles/x\n')
            self.assertEqual(run(),'/profiles/x|--version')
            # Review: `source ~/.zshrc && claude` ran before preexec existed and used the Mac login.
            self.assertEqual(subprocess.run(['zsh','-fc',f"source {rc} && {fake}/claude --version"],capture_output=True,text=True).stdout.strip(),'/profiles/x|--version')
            # Review: the Mac login must be selected explicitly (empty), or an exported
            # CLAUDE_CONFIG_DIR would pick that directory's login instead.
            selector.write_text('\n')
            self.assertEqual(run(),'|--version')
            # Review: shells opened before switching was turned off must stop following Side A.
            bridge.set_shell(self.root,False)
            self.assertFalse(selector.exists())
            self.assertEqual(subprocess.run(['zsh','-fc',f"PATH={fake}:$PATH; {bridge.shell_snippet(self.root).splitlines()[1]}; _side_a_select; claude --version"],
                                            capture_output=True,text=True).stdout.strip(),'unset|--version')
        self.assertEqual(rc.read_text(),mine)
    def test_limit_hook_is_silent_rate_limit_only_and_removable(self):
        home=self.root/'home'; (home/'.claude').mkdir(parents=True)
        mine={'matcher':'rate_limit','hooks':[{'type':'command','command':'notify-me'}]}
        bridge.atomic_json(home/'.claude/settings.json',{'model':'opus','hooks':{'StopFailure':[mine]}})
        with patch.object(Path,'home',return_value=home):
            bridge.set_limit_hook(self.root,True); bridge.set_limit_hook(self.root,True)
            added=bridge.read_json(home/'.claude/settings.json')['hooks']['StopFailure']
            self.assertEqual(len(added),2)
            self.assertEqual(added[1]['matcher'],'rate_limit')
            subprocess.run(added[1]['hooks'][0]['command'],shell=True,check=True)
            self.assertTrue(bridge.limit_marker(self.root).exists())
            bridge.set_limit_hook(self.root,False)
            self.assertEqual(bridge.read_json(home/'.claude/settings.json'),{'model':'opus','hooks':{'StopFailure':[mine]}})
    def test_fable_maps_to_opus_only_while_side_a_asks_and_keeps_the_users_own_value(self):
        fake=self.root/'bin'; fake.mkdir(); (fake/'claude').write_text('#!/bin/sh\necho "${ANTHROPIC_DEFAULT_FABLE_MODEL-unset}"\n'); (fake/'claude').chmod(0o755)
        line=bridge.shell_snippet(self.root).splitlines()[1]
        run=lambda before='': subprocess.run(['zsh','-fc',f"PATH={fake}:$PATH; {before} {line}; _side_a_select; claude"],
                                             capture_output=True,text=True).stdout.strip()
        self.assertEqual(run(),'unset')
        bridge.set_fable_fallback(self.root,True)
        self.assertEqual(run(),bridge.FABLE_FALLBACK_MODEL)
        # Turned off again: a shell that had the remap drops it, but a value the user exported stays.
        bridge.set_fable_fallback(self.root,False)
        self.assertEqual(run('export ANTHROPIC_DEFAULT_FABLE_MODEL=mine;'),'mine')
        self.assertEqual(subprocess.run(['zsh','-fc',f"PATH={fake}:$PATH; {line}; _side_a_select; rm {bridge.fable_model_path(self.root)}; _side_a_select; claude"],
                                        capture_output=True,text=True).stdout.strip(),'unset')
    def test_opus_fallback_never_overwrites_or_removes_the_users_own_value(self):
        home=self.root/'home'; (home/'.claude').mkdir(parents=True)
        settings=home/'.claude/settings.json'
        bridge.atomic_json(settings,{'model':'opus'})
        with patch.object(Path,'home',return_value=home):
            bridge.set_opus_fallback(True)
            self.assertEqual(bridge.read_json(settings),{'model':'opus','fallbackModel':['opus']})
            bridge.set_opus_fallback(False)
            self.assertEqual(bridge.read_json(settings),{'model':'opus'})
            bridge.atomic_json(settings,{'fallbackModel':['sonnet']})
            bridge.set_opus_fallback(True); bridge.set_opus_fallback(False)
            self.assertEqual(bridge.read_json(settings),{'fallbackModel':['sonnet']})
            self.assertTrue(bridge.opus_fallback_installed())
    def test_sessions_report_model_and_account_from_profile_environment(self):
        home=self.root/'home'; sessions=home/'.claude/sessions'; sessions.mkdir(parents=True)
        project=home/'.claude/projects/-x'; project.mkdir(parents=True)
        a={'id':str(uuid.uuid4()),'name':'A','email':'a@x'}; b={'id':str(uuid.uuid4()),'name':'B','email':'b@x'}
        for pid,sid in ((101,'s1'),(102,'s2'),(103,'s3')):
            bridge.atomic_json(sessions/f'{pid}.json',{'pid':pid,'sessionId':sid,'cwd':'/w','name':f'n{pid}','status':'busy'})
        (project/'s1.jsonl').write_text(json.dumps({'type':'assistant','message':{'model':'claude-fable-5-1'}})+'\n'
                                        +json.dumps({'type':'assistant','message':{'model':'<synthetic>'}})+'\n')
        envs={101:f"claude CLAUDE_SECURESTORAGE_CONFIG_DIR={self.root}/my dir/profiles/{b['id']} TERM=x",102:'claude TERM=x'}
        def ps(command,**_):
            if '-axo' in command:  # running_jobs: session 101 has a training run going
                return subprocess.CompletedProcess(command,0,'500 101 /bin/zsh -c source /x/shell-snapshots/s.sh && train\n','')
            pid=int(command[-1]); return subprocess.CompletedProcess(command,0 if pid in envs else 1,envs.get(pid,''),'')
        with patch.object(Path,'home',return_value=home), patch.object(bridge.subprocess,'run',side_effect=ps), \
             patch.object(bridge,'mac_email',return_value='a@x'), patch.object(bridge,'read_secret',return_value=None):
            result=bridge.live_sessions(self.root,{'accounts':[a,b]})
        self.assertEqual(result,[{'limitHit':None,'limitAt':None,'lastActivity':None,'turnEnded':False,'runningJobs':1,'pid':101,'name':'n101','status':'busy','entrypoint':None,'statusSince':None,'model':'claude-fable-5-1','accountID':b['id']},
                                 {'limitHit':None,'limitAt':None,'lastActivity':None,'turnEnded':False,'runningJobs':0,'pid':102,'name':'n102','status':'busy','entrypoint':None,'statusSince':None,'model':None,'accountID':a['id']}])
    def test_a_session_is_attributed_to_whoever_its_slot_login_belongs_to(self):
        home=self.root/'home'; sessions=home/'.claude/sessions'; sessions.mkdir(parents=True)
        a={'id':str(uuid.uuid4()),'name':'A','email':'a@x'}; b={'id':str(uuid.uuid4()),'name':'B','email':'b@x'}
        bridge.atomic_json(sessions/'101.json',{'pid':101,'sessionId':'s1','cwd':'/w'})
        env=f"claude CLAUDE_SECURESTORAGE_CONFIG_DIR={self.root}/profiles/{b['id']}"
        ps=lambda command,**_: subprocess.CompletedProcess(command,0,env,'')
        # `/login` as A inside a session on B's slot left A's login there.
        with patch.object(Path,'home',return_value=home), patch.object(bridge.subprocess,'run',side_effect=ps), \
             patch.object(bridge,'read_secret',return_value={'claudeAiOauth':{}}), patch.object(bridge,'token_email',return_value='a@x'):
            self.assertEqual(bridge.live_sessions(self.root,{'accounts':[a,b]})[0]['accountID'],a['id'])
    def test_sessions_are_found_by_title_or_tty_and_never_guessed(self):
        terms=[{'id':'T1','cwd':'/a','title':'Fix login'},{'id':'T2','cwd':'/a','title':'other'},{'id':'T3','cwd':'/b','title':'zsh'}]
        a1={'pid':1,'sessionId':'s1','cwd':'/a','name':'a-1'}; a2={'pid':2,'sessionId':'s2','cwd':'/a','name':'a-2'}
        b1={'pid':3,'sessionId':'s3','cwd':'/b','name':'b-1'}
        titles={'s1':{'a-1','Fix login'},'s2':{'a-2'},'s3':{'b-1'}}
        with patch.object(bridge,'session_titles',side_effect=lambda s: titles[s['sessionId']]):
            self.assertEqual(bridge.session_terminal(a1,[a1,a2,b1],terms)['id'],'T1')
            # A lone tab in the same folder is not enough: it may be a plain shell.
            with patch.object(bridge,'terminal_by_tty',return_value=None):
                with self.assertRaisesRegex(ValueError,'Ghostty tab'): bridge.session_terminal(b1,[a1,a2,b1],terms)
            # Two tabs in one folder and no title match: refuse rather than type into the wrong one.
            with patch.object(bridge,'terminal_by_tty',return_value=None):
                with self.assertRaisesRegex(ValueError,'Ghostty tab'): bridge.session_terminal(a2,[a1,a2,b1],terms)
            with patch.object(bridge,'terminal_by_tty',return_value=terms[1]):
                self.assertEqual(bridge.session_terminal(a2,[a1,a2,b1],terms)['id'],'T2')
    def test_resume_keeps_the_sessions_own_flags_and_replaces_conversation_and_model(self):
        argv=['claude','--dangerously-skip-permissions','--resume','old','-c','--model','opus','--permission-mode','plan',
              '-n','x','--add-dir','/tmp','/x y','--append-system-prompt','be brief please','--unknown','v']
        self.assertEqual(bridge.resume_command(1,'S','claude-fable-5-1','xhigh',argv=argv),
            ['claude','--resume','S','--dangerously-skip-permissions','--permission-mode','plan','--add-dir','/tmp','/x y',
             '--append-system-prompt','be brief please','--model','fable','--effort','xhigh'])
        self.assertEqual(bridge.resume_command(1,'S',None,'ultracode',argv=['claude'])[-1],'S')
    def test_resume_never_resends_the_prompt_and_keeps_a_1m_model(self):
        # Review: `claude "fix the tests"` resumed as `claude --resume S fix the tests`, and opus[1m] became opus.
        argv=['claude','--model','opus[1m]','fix the tests']
        self.assertEqual(bridge.resume_command(1,'S','claude-opus-5-5','high',argv=argv),
                         ['claude','--resume','S','--model','opus[1m]','--effort','high'])
        # A different model than the one launched with: the transcript's model wins.
        self.assertEqual(bridge.resume_command(1,'S','claude-fable-5-1',None,argv=argv)[-2:],['--model','fable'])
    def test_exact_argv_keeps_arguments_with_spaces(self):
        command=[sys.executable,'-c','import time; time.sleep(30)','a b']
        child=subprocess.Popen(command)
        try:
            time.sleep(0.3)
            self.assertEqual(bridge.proc_argv(child.pid)[-2:],['import time; time.sleep(30)','a b'])
        finally:
            child.kill(); child.wait()
    def test_a_limit_error_reply_is_read_as_the_limit_the_session_hit(self):
        home=self.root/'home'; project=home/'.claude/projects/-x'; project.mkdir(parents=True)
        error=lambda text: json.dumps({'type':'assistant','isApiErrorMessage':True,'error':'rate_limit','timestamp':'2026-10-07T20:00:00Z',
                                       'message':{'model':'<synthetic>','content':[{'type':'text','text':text}]}})
        ok=json.dumps({'type':'assistant','message':{'model':'claude-fable-5-1','content':[{'type':'text','text':'done'}]}})
        (project/'f.jsonl').write_text(ok+'\n'+error("You've reached your Fable limit. Run /usage-credits to continue")+'\n')
        (project/'w.jsonl').write_text(error("You've hit your weekly limit · resets Oct 9 at 7am")+'\n')
        (project/'r.jsonl').write_text(error("You've hit your session limit · resets 9:40pm")+'\n'+ok+'\n')
        with patch.object(Path,'home',return_value=home):
            self.assertEqual(bridge.session_limit('f'),('fable',bridge.epoch('2026-10-07T20:00:00Z')))
            self.assertEqual(bridge.session_limit('w')[0],'weekly')
            self.assertEqual(bridge.session_limit('r'),(None,None))  # a later normal reply: recovered
    def test_model_is_found_behind_long_tool_output(self):
        home=self.root/'home'; project=home/'.claude/projects/-x'; project.mkdir(parents=True)
        reply=json.dumps({'type':'assistant','effort':'high','message':{'model':'claude-opus-5-5','content':[]}})
        output=json.dumps({'type':'user','message':{'content':'x'*400000}})
        (project/'s.jsonl').write_text(reply+'\n'+output+'\n')
        with patch.object(Path,'home',return_value=home):
            self.assertEqual(bridge.session_state('s'),('claude-opus-5-5','high'))
    def test_activity_tells_a_finished_turn_from_a_stuck_one(self):
        home=self.root/'home'; project=home/'.claude/projects/-x'; project.mkdir(parents=True)
        entry=lambda kind,ts,**extra: json.dumps({'type':kind,'timestamp':ts,**extra})
        (project/'done.jsonl').write_text(entry('assistant','2026-10-07T20:00:00Z')+'\n'+entry('system','2026-10-07T20:00:05Z',subtype='turn_duration')+'\n')
        (project/'mid.jsonl').write_text(entry('assistant','2026-10-07T20:00:00Z')+'\n'+entry('user','2026-10-07T20:01:00Z')+'\n')
        with patch.object(Path,'home',return_value=home):
            self.assertEqual(bridge.session_activity('done'),(bridge.epoch('2026-10-07T20:00:05Z'),True))
            self.assertEqual(bridge.session_activity('mid'),(bridge.epoch('2026-10-07T20:01:00Z'),False))
    def test_a_half_written_session_file_is_skipped(self):
        home=self.root/'home'; sessions=home/'.claude/sessions'; sessions.mkdir(parents=True)
        (sessions/'1.json').write_text('{"pid": 1, "sess')
        with patch.object(Path,'home',return_value=home):
            self.assertEqual(bridge.live_sessions(self.root,{'accounts':[]}),[])
    def test_live_statusline_keeps_the_users_line_and_saves_each_accounts_limits(self):
        home=self.root/'home'; (home/'.claude').mkdir(parents=True)
        mine={'type':'command','command':"printf 'mine:'; cat",'padding':2}
        bridge.atomic_json(home/'.claude/settings.json',{'model':'opus','statusLine':mine})
        other=account('Other'); config={'accounts':[other]}
        payload='{"model":{"id":"x"},"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":2000000000},"seven_day":{"used_percentage":40,"resets_at":2000500000}}}\n\n'
        with patch.object(Path,'home',return_value=home):
            bridge.set_live(self.root,True); bridge.set_live(self.root,True)
            line=bridge.read_json(home/'.claude/settings.json')['statusLine']
            self.assertEqual(line['padding'],2)
            run=lambda env: subprocess.run(['/bin/zsh','-c',line['command']],input=payload,capture_output=True,text=True,
                                           env={**os.environ,**env}).stdout
            # The user's statusline sees the input byte for byte.
            self.assertEqual(run({'CLAUDE_SECURESTORAGE_CONFIG_DIR':str(self.root/'profiles'/other['id'])+'/'}),'mine:'+payload)
            with patch.object(bridge,'mac_email',return_value=None):
                live=bridge.live_limits(self.root,config)
            self.assertEqual(live[other['id']]['windows'][0],{'id':'five_hour','label':'5-hour','percent':12.0,'resetsAt':2000000000.0})
            self.assertEqual(live[other['id']]['windows'][1]['percent'],40.0)
            # A session with no limits yet (or a broken file) adds nothing.
            run({'CLAUDE_SECURESTORAGE_CONFIG_DIR':''}); (bridge.live_dir(self.root)/'junk.json').write_text('[')
            with patch.object(bridge,'mac_email',return_value=None):
                self.assertEqual(set(bridge.live_limits(self.root,config)),{other['id']})
            bridge.set_live(self.root,False)
            self.assertEqual(bridge.read_json(home/'.claude/settings.json'),{'model':'opus','statusLine':mine})
            bridge.atomic_json(home/'.claude/settings.json',{})
            bridge.set_live(self.root,True)
            self.assertEqual(subprocess.run(['/bin/sh','-c',bridge.read_json(home/'.claude/settings.json')['statusLine']['command']],
                                            input=payload,capture_output=True,text=True).stdout,'')
            bridge.set_live(self.root,False)
            self.assertEqual(bridge.read_json(home/'.claude/settings.json'),{})
            # A statusline that only mentions the marker is the user's, never unwrapped or dropped.
            theirs={'type':'command','command':"printf '%s' 'printf EXECUTED # side-a-live'"}
            bridge.atomic_json(home/'.claude/settings.json',{'statusLine':theirs})
            bridge.set_live(self.root,True); bridge.set_live(self.root,False)
            self.assertEqual(bridge.read_json(home/'.claude/settings.json'),{'statusLine':theirs})
    def test_report_counts_each_response_once_per_day_and_project(self):
        folder=Path(self.temp.name)/'home/.claude/projects/p'; folder.mkdir(parents=True)
        line=lambda mid,ts,out:json.dumps({'timestamp':ts,'cwd':'/work/app','requestId':'r'+mid,'message':{'id':mid,'model':'m','usage':{'input_tokens':1,'output_tokens':out}}})
        (folder/'s.jsonl').write_text('\n'.join([line('a','2026-10-01T15:00:00Z',5),line('a','2026-10-01T15:00:00Z',5),line('b','2026-10-01T17:30:00Z',7)])+'\n')
        with patch.object(Path,'home',return_value=Path(self.temp.name)/'home'), patch.object(bridge.time,'time',return_value=(folder/'s.jsonl').stat().st_mtime):
            result=bridge.report(self.root,days=10000)
        self.assertEqual([(r['project'],r['input'],r['output']) for r in result['projects']],[('/work/app',2,12)])
        self.assertEqual(len(result['activity']),1)
        self.assertEqual(sum(result['activity'][0]['hours']),2)
        self.assertEqual([(r['date'],r['model'],r['output']) for r in result['dayModels']],[('2026-10-01','m',12)])
        # A live session appends: only new bytes are read, a response split across the seam
        # counts once, and a half-written last line waits for the next scan.
        with open(folder/'s.jsonl','a') as stream:
            stream.write(line('b','2026-10-01T17:30:00Z',7)+'\n'+line('c','2026-10-01T18:00:00Z',9)+'\n'+line('d','2026-10-01T18:05:00Z',100)[:30])
        with patch.object(Path,'home',return_value=Path(self.temp.name)/'home'), patch.object(bridge.time,'time',return_value=(folder/'s.jsonl').stat().st_mtime), \
             patch.object(bridge,'json',wraps=json) as spy:
            result=bridge.report(self.root,days=10000)
        self.assertEqual([(r['input'],r['output']) for r in result['projects']],[(3,21)])
        self.assertEqual(sum(1 for c in spy.loads.call_args_list if 'usage' in str(c)),2)

    def test_codex_sessions_count_each_turn_once(self):
        # Codex logs a running total per token_count event, sometimes repeated; only the growth counts.
        folder=Path(self.temp.name)/'home/.codex/sessions/2026/10/01'; folder.mkdir(parents=True)
        tc=lambda ts,inp,cached,out:json.dumps({'timestamp':ts,'type':'event_msg','payload':{'type':'token_count','info':{'total_token_usage':{'input_tokens':inp,'cached_input_tokens':cached,'output_tokens':out}}}})
        lines=[json.dumps({'timestamp':'2026-10-01T15:00:00Z','type':'turn_context','payload':{'model':'gpt-6.1-sol','cwd':'/work/app'}}),
               tc('2026-10-01T15:00:05Z',100,40,10),tc('2026-10-01T15:00:05Z',100,40,10),tc('2026-10-01T15:01:00Z',250,140,30)]
        (folder/'rollout.jsonl').write_text('\n'.join(lines)+'\n')
        with patch.object(Path,'home',return_value=Path(self.temp.name)/'home'), patch.object(bridge.time,'time',return_value=(folder/'rollout.jsonl').stat().st_mtime):
            result=bridge.report(self.root,days=10000)
        self.assertEqual([(r['model'],r['input'],r['cacheRead'],r['output']) for r in result['models']],[('gpt-6.1-sol',110,140,30)])
        # After compaction the running total restarts lower; each turn's own usage still counts.
        tl=lambda ts,total,last:json.dumps({'timestamp':ts,'type':'event_msg','payload':{'type':'token_count','info':{'total_token_usage':total,'last_token_usage':last}}})
        with open(folder/'rollout.jsonl','a') as stream:
            stream.write(tl('2026-10-01T15:02:00Z',{'input_tokens':50,'output_tokens':5},{'input_tokens':50,'output_tokens':5})+'\n')
        with patch.object(Path,'home',return_value=Path(self.temp.name)/'home'), patch.object(bridge.time,'time',return_value=(folder/'rollout.jsonl').stat().st_mtime):
            result=bridge.report(self.root,days=10000)
        self.assertEqual([(r['input'],r['output']) for r in result['models']],[(160,35)])

    def test_two_macs_share_totals_through_sync_folder_without_logins(self):
        sync=Path(self.temp.name)/'icloud'
        line=lambda mid,out:json.dumps({'timestamp':'2026-10-01T15:00:00Z','cwd':'/w','requestId':mid,'message':{'id':mid,'model':'claude-fable-5-1','usage':{'output_tokens':out}}})
        macs=[]
        for name,out,email in (('a',5,'a@example.com'),('b',7,'b@example.com')):
            home=Path(self.temp.name)/name; folder=home/'.claude/projects/p'; folder.mkdir(parents=True)
            (folder/'s.jsonl').write_text(line(name,out)+'\n')
            root=home/'support'; root.mkdir()
            (root/'config.json').write_text(json.dumps({'accounts':[dict(account('Shared'),email='shared@example.com'),dict(account(name),email=email)]}))
            macs.append((home,root,folder/'s.jsonl'))
        def run(home,root,path):
            with patch.object(Path,'home',return_value=home), patch.object(bridge.time,'time',return_value=path.stat().st_mtime), \
                 patch.object(bridge,'machine_identity',return_value=(home.name,home.name)):
                return bridge.report(root,days=10000,sync=sync)
        run(*macs[0])
        # A broken or hostile file from the shared folder is skipped or bounded, never fatal.
        (sync/'machines/bad.json').write_text('{broken')
        (sync/'machines/odd.json').write_text(json.dumps({'updated':macs[0][2].stat().st_mtime,'totals':[1],'hours':{}}))
        (sync/'machines/huge.json').write_text(json.dumps({'updated':macs[0][2].stat().st_mtime,'totals':{},'hours':{'2026-10-01':[10**30]*24}}))
        result=run(*macs[1])
        self.assertEqual([r['output'] for r in result['days']],[12])
        self.assertEqual(result['activity'][0]['hours'][0],10**6)
        self.assertEqual(sorted(m['current'] for m in result['machines']),[False,False,True])
        # Only the account this Mac lacks is offered; the shared one is already here.
        self.assertEqual([(a['email'],a['provider']) for a in result['elsewhere']],[('a@example.com','claude')])
        for path in (sync/'machines').glob('[ab].json'):
            self.assertEqual(set(bridge.read_json(path)),{'name','updated','totals','hours','accounts'})
            self.assertNotIn('claudeAiOauth',path.read_text())

    def test_recent_model_is_the_newest_sessions_last_response(self):
        folder=Path(self.temp.name)/'home/.claude/projects/p'; folder.mkdir(parents=True)
        now=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())
        msg=lambda model,ts=now:json.dumps({'type':'assistant','timestamp':ts,'message':{'model':model}})
        # A large tool result after the last response still leaves the response findable.
        (folder/'s.jsonl').write_text('\n'.join([msg('claude-opus-5-5'),msg('claude-fable-5-1'),msg('<synthetic>'),json.dumps({'type':'user','x':'y'*600000})])+'\n')
        with patch.object(Path,'home',return_value=Path(self.temp.name)/'home'):
            self.assertEqual(bridge.recent_model(),'claude-fable-5-1')
            # A recently touched file whose last response is old does not count.
            (folder/'s.jsonl').write_text(msg('claude-fable-5-1','2026-01-01T00:00:00Z')+'\n')
            self.assertIsNone(bridge.recent_model())
            os.utime(folder/'s.jsonl',(time.time()-7200,time.time()-7200))
            self.assertIsNone(bridge.recent_model())

    def test_an_idle_unverified_login_can_be_woken_but_only_as_its_own_account(self):
        # An expired login can't be looked up, so requiring a lookup before waking it deadlocked:
        # it never refreshed and the account read "Reading..." forever.
        a=account('Alpha'); blob={'claudeAiOauth':{'accessToken':'t','expiresAt':1}}
        ran=[]
        with patch.object(bridge,'read_secret',return_value=blob), patch.object(bridge,'mac_email',return_value=''), \
             patch.object(bridge,'claude_binary',return_value='claude'), \
             patch.object(bridge.subprocess,'run',side_effect=lambda *x,**k: ran.append(x[0]) or subprocess.CompletedProcess(x[0],0)):
            with patch.object(bridge,'auth_status',return_value={'email':'ALPHA@example.com'}):
                bridge.prime(self.root,{'accounts':[a]},a)
            self.assertEqual(len(ran),1)
            with patch.object(bridge,'auth_status',return_value={'email':'other@example.com'}):
                with self.assertRaisesRegex(ValueError,'Sign in to Alpha'): bridge.prime(self.root,{'accounts':[a]},a)
            self.assertEqual(len(ran),1)

    def test_one_terminal_can_stay_on_an_account_while_the_rest_follow_side_a(self):
        root=self.root/'Side A'; (root/'runtime').mkdir(parents=True)
        (root/'runtime/claude-selector').write_text('/profiles/default\n')
        a=account('Long Jobs'); b=account('Studio')
        with patch.object(bridge,'read_secret',return_value=None), patch.object(bridge,'mac_email',return_value=''):
            bridge.write_pins(root,{'accounts':[a,b]})
        self.assertEqual(sorted(p.name for p in bridge.pins_path(root).iterdir()),['long-jobs','studio'])
        script=bridge.shell_snippet(root).split('\n',1)[1]+'''
show() { _side_a_select; echo "${CLAUDE_SECURESTORAGE_CONFIG_DIR:-unset}"; }
sidea use Long-Jobs >/dev/null; show
sidea auto >/dev/null; show
sidea use nobody >/dev/null; show
export SIDE_A_PIN=studio; rm '%s'/studio; show
''' % bridge.pins_path(root)
        out=subprocess.run(['zsh','-fc',script],capture_output=True,text=True,check=True).stdout.splitlines()
        pinned=str(bridge.profile_dir(root,a['id']))
        # Pinned, back to Side A's choice, an unknown name changes nothing, a removed account falls back.
        self.assertEqual(out,[pinned,'/profiles/default','/profiles/default','/profiles/default'])

    def test_paid_usage_reads_in_dollars_from_the_live_shape(self):
        # Shapes as the usage endpoint returned them: spend in minor units, extra_usage in cents.
        capped={'extra_usage':{'is_enabled':False,'monthly_limit':1000,'used_credits':0.0,'currency':'USD'},
                'spend':{'used':{'amount_minor':0,'currency':'USD','exponent':2},'limit':{'amount_minor':1000,'currency':'USD','exponent':2},'enabled':False}}
        self.assertEqual(bridge.extra_usage(capped),{'enabled':False,'used':0.0,'limit':10.0,'currency':'USD'})
        billing={'spend':{'used':{'amount_minor':320,'currency':'USD','exponent':2},'limit':None,'enabled':True}}
        self.assertEqual(bridge.extra_usage(billing),{'enabled':True,'used':3.2,'limit':None,'currency':'USD'})
        self.assertEqual(bridge.extra_usage({'extra_usage':{'is_enabled':True,'used_credits':250,'monthly_limit':None}})['used'],2.5)

    def test_side_a_waits_for_claude_codes_refresh_lock_and_releases_it(self):
        # A wake refreshing at the same moment as an open session can get a login revoked.
        lock=self.root/'claude-home/.oauth_refresh.lock'; lock.mkdir(parents=True)
        with self.assertRaisesRegex(ValueError,'refreshing a login'):
            with bridge.claude_refresh_lock(self.root/'claude-home',timeout=1): pass
        self.assertTrue(lock.exists())  # someone else's live lock is left alone
        old=time.time()-120; os.utime(lock,(old,old))
        with bridge.claude_refresh_lock(self.root/'claude-home',timeout=1):
            self.assertTrue(lock.exists())  # a stale lock is taken over, and held while claude runs
        self.assertFalse(lock.exists())

    def test_a_busy_login_trades_only_when_shared(self):
        a=account('Alpha'); b=account('Beta'); config={'accounts':[a,b]}
        login=lambda who: {'claudeAiOauth':{'accessToken':f'{who}-at','refreshToken':f'{who}-rt','expiresAt':(time.time()+3600)*1000}}
        mac=bridge.GLOBAL_SERVICE; beta=bridge.profile_service(self.root,b['id'])
        keychain={mac:login('alpha'), beta:login('beta')}
        owner=lambda root,blob: ((blob or {}).get('claudeAiOauth') or {}).get('accessToken','').split('-')[0]+'@example.com' if blob else ''
        reader=MagicMock(side_effect=lambda svc: keychain.get(svc)); reader.cache_clear=lambda: None
        real_run=subprocess.run
        def run(args,*rest,**kw):
            if args[:2]==['security','delete-generic-password']: keychain.pop(args[-1],None); return subprocess.CompletedProcess(args,0)
            return real_run(args,*rest,**kw)
        home=self.root/'home'; (home/'.claude').mkdir(parents=True)
        with patch.object(bridge,'read_secret',reader), patch.object(bridge,'write_secret',side_effect=lambda svc,blob: keychain.__setitem__(svc,blob)), \
             patch.object(bridge,'token_email',side_effect=owner), patch.object(bridge,'mac_email',side_effect=lambda root: owner(root,keychain[mac])), \
             patch.object(bridge.subprocess,'run',side_effect=run), patch.object(Path,'home',return_value=home), \
             patch.object(bridge,'busy_slots',return_value={b['id']}):
            with self.assertRaisesRegex(ValueError,'using that account'): bridge.swap(self.root,config,'mac',b)
            bridge.swap(self.root,config,'mac',b,share=True)
        self.assertEqual(keychain[mac]['claudeAiOauth']['refreshToken'],'beta-rt')
        self.assertEqual(keychain[beta]['claudeAiOauth']['refreshToken'],'alpha-rt')
    def test_swapping_moves_logins_between_items_and_a_crash_finishes_forward(self):
        a=account('Alpha'); b=account('Beta'); config={'accounts':[a,b]}
        login=lambda who,n=1,exp=3600: {'claudeAiOauth':{'accessToken':f'{who}-at{n}','refreshToken':f'{who}-rt{n}','expiresAt':(time.time()+exp)*1000},'organizationUuid':who+'-org'}
        mac=bridge.GLOBAL_SERVICE; beta=bridge.profile_service(self.root,b['id'])
        keychain={mac:{**login('alpha'),'mcpOAuth':{'srv':'mac-mcp'}}, beta:login('beta')}
        owner=lambda root,blob: ((blob or {}).get('claudeAiOauth') or {}).get('accessToken','').split('-')[0]+'@example.com' if blob else ''
        reader=MagicMock(side_effect=lambda svc: keychain.get(svc)); reader.cache_clear=lambda: None
        writes=[]; fail=[False]
        def write(svc,blob):
            writes.append(svc)
            if fail[0] and svc==beta: raise ValueError('keychain refused')
            keychain[svc]=blob
        real_run=subprocess.run
        def run(args,*rest,**kw):
            if args[:2]==['security','delete-generic-password']: keychain.pop(args[-1],None); return subprocess.CompletedProcess(args,0)
            return real_run(args,*rest,**kw)
        home=self.root/'home'; (home/'.claude').mkdir(parents=True)
        tokens=lambda: sorted(x['claudeAiOauth']['refreshToken'] for k,x in keychain.items() if k!=bridge.SWAP_JOURNAL)
        with patch.object(bridge,'read_secret',reader), patch.object(bridge,'write_secret',side_effect=write), \
             patch.object(bridge,'token_email',side_effect=owner), patch.object(bridge,'mac_email',side_effect=lambda root: owner(root,keychain[mac])), \
             patch.object(bridge.subprocess,'run',side_effect=run), patch.object(Path,'home',return_value=home), \
             patch.object(bridge,'busy_slots',return_value=set()):
            # The keychain fails after the Mac item took Beta's login: the journal still holds Alpha.
            fail[0]=True
            with self.assertRaises(ValueError): bridge.swap(self.root,config,'mac',b)
            self.assertIn(bridge.SWAP_JOURNAL,keychain)
            # Meanwhile a session renews Beta in its old item; finishing uses that newest copy, never the spent one.
            keychain[beta]={'claudeAiOauth':{'accessToken':'nobody','refreshToken':'beta-rt2','expiresAt':(time.time()+7200)*1000}}
            fail[0]=False
            with bridge.selection_lock(self.root), bridge.selection_lock(self.root,'renew.lock'): bridge.finish_swap(self.root)
            self.assertNotIn(bridge.SWAP_JOURNAL,keychain)
            self.assertEqual(keychain[mac]['claudeAiOauth']['refreshToken'],'beta-rt2')
            self.assertEqual(keychain[mac]['mcpOAuth'],{'srv':'mac-mcp'})
            self.assertEqual(keychain[beta]['claudeAiOauth']['refreshToken'],'alpha-rt1'); self.assertNotIn('mcpOAuth',keychain[beta])
            self.assertEqual(tokens(),['alpha-rt1','beta-rt2'])
            keychain[mac]['claudeAiOauth']['accessToken']='beta-at2'  # its owner is looked up later
            self.assertEqual((bridge.home_service(self.root,a),bridge.home_service(self.root,b)),(beta,mac))
            self.assertEqual(bridge.selector_for(self.root,b),'')
            self.assertEqual(bridge.owned_login(self.root,a)['claudeAiOauth']['accessToken'],'alpha-at1')
            self.assertFalse((home/'.claude/.oauth_refresh.lock').exists())
            # A statusline that was mid-write during the trade keeps its old time and is not credited to Beta.
            bridge.live_dir(self.root).mkdir(parents=True,exist_ok=True)
            stale=bridge.live_dir(self.root)/'mac.json'; stale.write_text(json.dumps({'rate_limits':{'five_hour':{'used_percentage':99,'resets_at':2000000000}}}))
            os.utime(stale,(time.time()-5,time.time()-5))
            self.assertEqual(bridge.live_limits(self.root,config),{})
            # Trading back restores the first layout with no map left behind.
            bridge.swap(self.root,config,'mac',a)
            self.assertEqual((keychain[mac]['claudeAiOauth']['refreshToken'],keychain[beta]['claudeAiOauth']['refreshToken']),('alpha-rt1','beta-rt2'))
            self.assertEqual(bridge.read_json(bridge.homes_path(self.root)),{})
            # The Mac item signed in to someone else: Beta's own profile holds Alpha, so Beta takes Alpha's empty slot.
            bridge.swap(self.root,config,'mac',b); keychain[mac]=login('carol')
            self.assertEqual((bridge.home_slot(self.root,a),bridge.home_slot(self.root,b)),(b['id'],a['id']))
    def test_busy_slots_follow_claude_codes_storage_rule(self):
        a=account('Alpha'); b=account('Beta'); config={'accounts':[a,b]}
        prof=lambda acct: str(bridge.profile_dir(self.root,acct['id']))
        listing='11 /usr/local/bin/claude\n12 /Users/x/.local/share/claude/versions/2.1.294\n13 /usr/bin/node\n14 claude\n'
        envs={11:('claude',{'CLAUDE_SECURESTORAGE_CONFIG_DIR':prof(b)}),
              # A prompt mentioning the variable is argv, not environment: only the real value counts.
              12:('claude',{'CLAUDE_SECURESTORAGE_CONFIG_DIR':''}),
              13:('node',{'CLAUDE_SECURESTORAGE_CONFIG_DIR':prof(a)}), 14:None}
        with patch.object(bridge.subprocess,'run',return_value=subprocess.CompletedProcess([],0,listing,'')), \
             patch.object(bridge,'process_environment',side_effect=lambda pid: envs[pid]):
            self.assertEqual(bridge.busy_slots(self.root,config),{b['id'],'mac'})
        with patch.object(bridge.subprocess,'run',side_effect=OSError):
            self.assertIsNone(bridge.busy_slots(self.root,config))
        # The real kernel read: a child's environment comes back exactly, even with argv that mimics it.
        child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(5)','CLAUDE_SECURESTORAGE_CONFIG_DIR=/fake'],env={'CLAUDE_SECURESTORAGE_CONFIG_DIR':'/real dir'})
        try:
            time.sleep(0.2)
            self.assertEqual(bridge.process_environment(child.pid)[1].get('CLAUDE_SECURESTORAGE_CONFIG_DIR'),'/real dir')
        finally:
            child.kill(); child.wait()
    def test_recovery_keeps_a_login_renewed_before_any_write(self):
        a=account('Alpha'); b=account('Beta')
        mac=bridge.GLOBAL_SERVICE; beta=bridge.profile_service(self.root,b['id'])
        login=lambda who,n,exp: {'claudeAiOauth':{'accessToken':f'{who}-at{n}','refreshToken':f'{who}-rt{n}','expiresAt':(time.time()+exp)*1000}}
        journal={'slots':['mac',b['id']],'moves':{b['id']:'mac',a['id']:b['id']},'logins':[login('alpha',1,60),login('beta',1,60)]}
        # Alpha renewed in the Mac item after the journal was saved; its new token's owner is unknown.
        keychain={bridge.SWAP_JOURNAL:journal, mac:{'claudeAiOauth':{'accessToken':'nobody','refreshToken':'alpha-rt2','expiresAt':(time.time()+9000)*1000}}, beta:login('beta',1,60)}
        owner=lambda root,blob: ((blob or {}).get('claudeAiOauth') or {}).get('accessToken','').split('-')[0]+'@example.com' if blob else ''
        reader=MagicMock(side_effect=lambda svc: keychain.get(svc)); reader.cache_clear=lambda: None
        def run(args,*rest,**kw):
            keychain.pop(args[-1],None); return subprocess.CompletedProcess(args,0)
        home=self.root/'home'; (home/'.claude').mkdir(parents=True)
        with patch.object(bridge,'read_secret',reader), patch.object(bridge,'write_secret',side_effect=lambda svc,blob: keychain.__setitem__(svc,blob)), \
             patch.object(bridge,'token_email',side_effect=owner), patch.object(bridge.subprocess,'run',side_effect=run), patch.object(Path,'home',return_value=home):
            with bridge.selection_lock(self.root), bridge.selection_lock(self.root,'renew.lock'): bridge.finish_swap(self.root)
        self.assertEqual((keychain[mac]['claudeAiOauth']['refreshToken'],keychain[beta]['claudeAiOauth']['refreshToken']),('beta-rt1','alpha-rt2'))
    def test_a_second_sign_in_moves_without_becoming_the_accounts_home(self):
        a=account('Alpha'); b=account('Beta'); config={'accounts':[a,b]}
        login=lambda who,n: {'claudeAiOauth':{'accessToken':f'{who}-at{n}','refreshToken':f'{who}-rt{n}','expiresAt':(time.time()+3600)*1000}}
        mac=bridge.GLOBAL_SERVICE; alpha=bridge.profile_service(self.root,a['id']); beta=bridge.profile_service(self.root,b['id'])
        # Alpha is the Mac login and also signed in separately in its own profile, where sessions run.
        keychain={mac:login('alpha',1), alpha:login('alpha',2), beta:login('beta',1)}
        owner=lambda root,blob: ((blob or {}).get('claudeAiOauth') or {}).get('accessToken','').split('-')[0]+'@example.com' if blob else ''
        reader=MagicMock(side_effect=lambda svc: keychain.get(svc)); reader.cache_clear=lambda: None
        def run(args,*rest,**kw):
            keychain.pop(args[-1],None); return subprocess.CompletedProcess(args,0)
        home=self.root/'home'; (home/'.claude').mkdir(parents=True)
        with patch.object(bridge,'read_secret',reader), patch.object(bridge,'write_secret',side_effect=lambda svc,blob: keychain.__setitem__(svc,blob)), \
             patch.object(bridge,'token_email',side_effect=owner), patch.object(bridge,'mac_email',side_effect=lambda root: owner(root,keychain[mac])), \
             patch.object(bridge.subprocess,'run',side_effect=run), patch.object(Path,'home',return_value=home), \
             patch.object(bridge,'busy_slots',return_value=set()):
            # A session started on Beta, or Beta signing in, blocks the trade: nothing lands on them.
            with patch.object(bridge,'busy_slots',return_value={b['id']}):
                with self.assertRaisesRegex(ValueError,'using that account'): bridge.swap(self.root,config,a['id'],b)
            bridge.signing_in_path(self.root,b['id']).write_text(str(os.getpid()))
            with self.assertRaisesRegex(ValueError,'signing in'): bridge.swap(self.root,config,a['id'],b)
            bridge.signing_in_path(self.root,b['id']).unlink()
            self.assertEqual(keychain[alpha]['claudeAiOauth']['refreshToken'],'alpha-rt2')
            bridge.swap(self.root,config,a['id'],b)
            self.assertEqual((keychain[alpha]['claudeAiOauth']['refreshToken'],keychain[beta]['claudeAiOauth']['refreshToken']),('beta-rt1','alpha-rt2'))
            # Alpha stays the Mac login; Beta now lives in Alpha's profile.
            self.assertEqual((bridge.home_slot(self.root,a),bridge.home_slot(self.root,b)),('mac',a['id']))
            self.assertEqual(keychain[mac]['claudeAiOauth']['refreshToken'],'alpha-rt1')
    def test_renewing_an_expired_login_spends_its_refresh_token_once_and_keeps_the_rest(self):
        a=account('Alpha'); login=lambda: {'claudeAiOauth':{'accessToken':'old','refreshToken':'r1','expiresAt':1,'scopes':['user:inference','user:profile'],'subscriptionType':'max'}}
        old=login()
        store={'blob':old}; posts=[]; fresh=lambda: {'claudeAiOauth':{**old['claudeAiOauth'],'accessToken':'session','expiresAt':(time.time()+3600)*1000}}
        def post(url,body,headers=None,method='POST'):
            posts.append(body); return {'access_token':'new','refresh_token':'r2','expires_in':28800}
        with patch.object(bridge,'mac_email',return_value=''), patch.object(bridge,'auth_status',return_value={'email':'alpha@example.com'}), \
             patch.object(bridge,'read_secret',side_effect=lambda svc: store['blob']) as reader, \
             patch.object(bridge,'write_secret',side_effect=lambda svc,blob: store.update(blob=blob)), patch.object(bridge,'post_json',side_effect=post):
            reader.cache_clear=lambda: None
            bridge.renew(self.root,{'accounts':[a]},a)
            self.assertEqual(posts[0]['refresh_token'],'r1'); self.assertEqual(posts[0]['client_id'],bridge.CLIENT_ID)
            renewed=store['blob']['claudeAiOauth']
            self.assertEqual((renewed['accessToken'],renewed['refreshToken'],renewed['subscriptionType']),('new','r2','max'))
            # A session that renewed it while Side A waited for the lock wins: nothing is spent twice.
            store['blob']=login(); seen=iter([login(),login(),fresh()])  # before the lock, then inside it
            with patch.object(bridge,'read_secret',side_effect=lambda svc: next(seen,store['blob'])) as again:
                again.cache_clear=lambda: None
                bridge.renew(self.root,{'accounts':[a]},a)
            self.assertEqual(len(posts),1)
        dead=bridge.urllib.error.HTTPError(bridge.TOKEN_URL,400,'invalid_grant',{},None)
        with patch.object(bridge,'mac_email',return_value=''), patch.object(bridge,'auth_status',return_value={'email':'alpha@example.com'}), \
             patch.object(bridge,'read_secret',return_value=login()) as reader, patch.object(bridge,'post_json',side_effect=dead), patch.object(bridge,'write_secret') as writer:
            reader.cache_clear=lambda: None
            with self.assertRaisesRegex(ValueError,'Sign in to Alpha again'): bridge.renew(self.root,{'accounts':[a]},a)
            writer.assert_not_called()

if __name__ == '__main__': unittest.main()
