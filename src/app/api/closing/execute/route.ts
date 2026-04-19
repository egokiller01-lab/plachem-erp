import { NextResponse } from 'next/server';
import { supabase } from '@/lib/supabase';

export async function POST(request: Request) {
  try {
    const body = await request.json();
    const { year, month } = body;

    if (!year || !month) {
      return NextResponse.json({ error: 'Year and month are required' }, { status: 400 });
    }

    // const { data: userData } = await supabase.auth.getUser();
    // const userId = userData.user?.id;
    const userId = '00000000-0000-0000-0000-000000000000'; // mock user id

    if (!userId) {
      return NextResponse.json({ error: 'Unauthorized: User ID not found' }, { status: 401 });
    }

    const { data, error } = await supabase.rpc('execute_monthly_closing', {
      p_year: year,
      p_month: month,
      p_user_uuid: userId
    });

    if (error) {
      console.error('Execution RPC error:', error);
      return NextResponse.json({ error: error.message }, { status: 500 });
    }

    if (data && data.success === false) {
      return NextResponse.json({ error: data.message, validation_errors: data.errors }, { status: 400 });
    }

    return NextResponse.json({ data }, { status: 200 });

  } catch (err: any) {
    return NextResponse.json({ error: err.message }, { status: 500 });
  }
}
